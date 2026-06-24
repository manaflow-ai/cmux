import CMUXAgentLaunch
import CmuxFoundation
import Foundation

extension SessionIndexStore {
    private struct RegisteredAgentJSONLMetadata {
        var title: String = ""
        var cwd: String?
        var branch: String?
        var sessionId: String?
    }

    private struct AntigravityHistoryMetadata {
        let sessionId: String
        let title: String
        let cwd: String?
        let modified: Date
        let fileURL: URL
    }

    nonisolated static func loadGrokEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        agent: SessionAgent = .grok,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> [SessionEntry] {
        let grokResolver = GrokSessionResolver(fileManager: fileManager)
        let observedGrokHomes = grokResolver.observedGrokHomes(
            hookStoreFileURL: RestorableAgentKind.grok.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            homeDirectory: homeDirectory
        )
        let roots = grokResolver.sessionRoots(
            sessionDirectory: registration.sessionDirectory,
            cwdFilter: cwdFilter,
            environment: environment,
            homeDirectory: homeDirectory,
            observedGrokHomes: observedGrokHomes
        )
        guard !roots.isEmpty else { return [] }
        let fm = fileManager
        let historyParser = AgentHistoryRecordParser()

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool, root: GrokSessionRoot)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepScanner.matchingPaths(
                    needle: needle,
                    root: root.sessionsRoot,
                    fileGlob: "chat_history.jsonl"
                ) else {
                    candidates.append(
                        contentsOf: enumerateGrokHistoryCandidates(root: root, fileManager: fileManager).map {
                            (url: $0.0, modified: $0.1, prefilteredByRipgrep: false, root: root)
                        }
                    )
                    continue
                }
                for url in rgPaths where url.lastPathComponent == "chat_history.jsonl" {
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let modified = attrs[.modificationDate] as? Date else {
                        continue
                    }
                    candidates.append((url, modified, true, root))
                }
            }
        } else {
            for root in roots {
                candidates.append(
                    contentsOf: enumerateGrokHistoryCandidates(root: root, fileManager: fileManager).map {
                        (url: $0.0, modified: $0.1, prefilteredByRipgrep: false, root: root)
                    }
                )
            }
        }

        candidates.sort { $0.modified > $1.modified }
        let target = offset + limit
        var matches: [SessionEntry] = []
        var seenSessionIds = Set<String>()
        var scanned = 0
        for candidate in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1

            if !needle.isEmpty && !candidate.prefilteredByRipgrep {
                guard historyParser.fileContains(candidate.url, needle: needle) else { continue }
            }

            let sessionDirectory = candidate.url.deletingLastPathComponent()
            let projectDirectory = sessionDirectory.deletingLastPathComponent().lastPathComponent
            let cwd = grokResolver.workingDirectory(fromProjectDirectoryName: projectDirectory)
            if let cwdFilter,
               grokResolver.normalizedWorkingDirectory(cwd)
                != grokResolver.normalizedWorkingDirectory(cwdFilter) {
                continue
            }

            let metadata = grokResolver.extractGrokSessionMetadata(url: candidate.url)
            let sessionId = sessionDirectory.lastPathComponent
            guard seenSessionIds.insert(sessionId).inserted else { continue }
            let specifics: AgentSpecifics
            switch agent {
            case .grok:
                specifics = .grok(
                    model: metadata.model,
                    permissionMode: metadata.permissionMode,
                    sandboxMode: metadata.sandboxMode,
                    grokHome: candidate.root.grokHomeForResume
                )
            default:
                specifics = .registered(
                    registrationWithGrokHomePrefix(
                        registration,
                        grokHome: candidate.root.grokHomeForResume
                    )
                )
            }
            matches.append(SessionEntry(
                id: "\(registration.id):\(sessionId)",
                agent: agent,
                sessionId: sessionId,
                title: metadata.title,
                cwd: cwd,
                gitBranch: metadata.branch,
                pullRequest: nil,
                modified: candidate.modified,
                fileURL: candidate.url,
                specifics: specifics
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    nonisolated static func loadRegisteredAgentEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) async -> [SessionEntry] {
        if registration.id == CmuxVaultAgentRegistration.builtInAntigravity.id {
            return loadAntigravityHistoryEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit
            )
        }

        if case .grokSessionDirectory = registration.sessionIdSource {
            return await loadGrokEntries(
                registration: registration,
                needle: needle,
                cwdFilter: cwdFilter,
                offset: offset,
                limit: limit,
                agent: .registered(RegisteredSessionAgent(registration: registration))
            )
        }
        let roots = registeredSessionRoots(registration: registration, cwdFilter: cwdFilter)
        guard !roots.isEmpty else { return [] }
        let fm = FileManager.default
        let historyParser = AgentHistoryRecordParser()

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepScanner.matchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") else {
                    candidates.append(
                        contentsOf: enumerateRegisteredJSONLCandidates(root: root).map {
                            (url: $0.0, modified: $0.1, prefilteredByRipgrep: false)
                        }
                    )
                    continue
                }
                for url in rgPaths {
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let modified = attrs[.modificationDate] as? Date else {
                        continue
                    }
                    candidates.append((url, modified, true))
                }
            }
        } else {
            for root in roots {
                candidates.append(
                    contentsOf: enumerateRegisteredJSONLCandidates(root: root).map {
                        (url: $0.0, modified: $0.1, prefilteredByRipgrep: false)
                    }
                )
            }
        }

        candidates.sort { $0.modified > $1.modified }
        let target = offset + limit
        var matches: [SessionEntry] = []
        var scanned = 0
        for candidate in candidates {
            if Task.isCancelled { break }
            if matches.count >= target { break }
            if scanned >= searchMaxFiles { break }
            scanned += 1

            if !needle.isEmpty && !candidate.prefilteredByRipgrep {
                guard historyParser.fileContains(candidate.url, needle: needle) else { continue }
            }

            let metadata = extractRegisteredJSONLMetadata(
                url: candidate.url,
                registration: registration,
                fallbackCWD: cwdFilter
            )
            if let cwdFilter, metadata.cwd != cwdFilter { continue }
            let sessionId = metadata.sessionId ?? candidate.url.path
            matches.append(SessionEntry(
                id: "\(registration.id):\(sessionId)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: sessionId,
                title: metadata.title,
                cwd: metadata.cwd,
                gitBranch: metadata.branch,
                pullRequest: nil,
                modified: candidate.modified,
                fileURL: candidate.url,
                specifics: .registered(registration)
            ))
        }
        return Array(matches.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func loadAntigravityHistoryEntries(
        registration: CmuxVaultAgentRegistration,
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int
    ) -> [SessionEntry] {
        let roots = registeredSessionRoots(registration: registration, cwdFilter: cwdFilter)
        guard !roots.isEmpty else { return [] }

        let fm = FileManager.default
        let fieldParser = AgentSessionFieldParser()
        let historyParser = AgentHistoryRecordParser(fieldParser: fieldParser)
        var latestBySessionID: [String: AntigravityHistoryMetadata] = [:]

        for root in roots {
            if Task.isCancelled { break }
            let historyURL = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("history.jsonl", isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: historyURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let fallbackModified = ((try? fm.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date)
                ?? Date.distantPast

            ripgrepScanner.forEachJSONLine(url: historyURL, maxBytes: Int.max) { object in
                if Task.isCancelled { return true }
                guard let sessionId = fieldParser.firstString(in: object, keys: historyParser.antigravitySessionIDKeys()) else {
                    return false
                }
                let cwd = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLCWDKeys())
                if let cwdFilter, cwd != cwdFilter { return false }

                let title = historyParser.antigravityHistoryTitle(in: object) ?? ""
                guard historyParser.antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    return false
                }

                let modified = historyParser.antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
                let metadata = AntigravityHistoryMetadata(
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd,
                    modified: modified,
                    fileURL: historyURL
                )
                if let existing = latestBySessionID[sessionId] {
                    if metadata.modified >= existing.modified {
                        latestBySessionID[sessionId] = metadata
                    }
                } else {
                    latestBySessionID[sessionId] = metadata
                }
                return false
            }
        }

        let entries = latestBySessionID.values
            .sorted {
                if $0.modified == $1.modified {
                    return $0.sessionId < $1.sessionId
                }
                return $0.modified > $1.modified
            }
            .map { metadata in
                SessionEntry(
                    id: "\(registration.id):\(metadata.sessionId)",
                    agent: .registered(RegisteredSessionAgent(registration: registration)),
                    sessionId: metadata.sessionId,
                    title: metadata.title,
                    cwd: metadata.cwd,
                    gitBranch: nil,
                    pullRequest: nil,
                    modified: metadata.modified,
                    fileURL: metadata.fileURL,
                    specifics: .registered(registration)
                )
            }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    nonisolated private static func registeredSessionRoots(
        registration: CmuxVaultAgentRegistration,
        cwdFilter: String?
    ) -> [String] {
        if case .grokSessionDirectory = registration.sessionIdSource {
            return GrokSessionResolver()
                .sessionRoots(sessionDirectory: registration.sessionDirectory, cwdFilter: cwdFilter)
                .map(\.sessionsRoot)
        }
        guard let root = registration.sessionDirectory.map({ ($0 as NSString).expandingTildeInPath }) else {
            return []
        }
        if case .piSessionFile = registration.sessionIdSource,
           let cwdFilter,
           let projectDirectory = PiSessionResolver().projectDirectoryName(for: cwdFilter) {
            return [(root as NSString).appendingPathComponent(projectDirectory)]
        }
        return [root]
    }

    nonisolated private static func registrationWithGrokHomePrefix(
        _ registration: CmuxVaultAgentRegistration,
        grokHome: String?
    ) -> CmuxVaultAgentRegistration {
        guard let grokHome = grokHome?.trimmingCharacters(in: .whitespacesAndNewlines),
              !grokHome.isEmpty,
              !registration.resumeCommand.contains("GROK_HOME") else {
            return registration
        }
        var copy = registration
        copy.resumeCommand = "env GROK_HOME=\(SessionEntry.shellQuote(grokHome)) \(registration.resumeCommand)"
        return copy
    }

    nonisolated private static func enumerateGrokHistoryCandidates(
        root: GrokSessionRoot,
        fileManager: FileManager
    ) -> [(URL, Date)] {
        let fm = fileManager
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.sessionsRoot, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: root.sessionsRoot, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "chat_history.jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            candidates.append((url, modified))
        }
        return candidates
    }

    nonisolated private static func enumerateRegisteredJSONLCandidates(root: String) -> [(URL, Date)] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: root, isDirectory: true),
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            candidates.append((url, modified))
        }
        return candidates
    }

    nonisolated private static func extractRegisteredJSONLMetadata(
        url: URL,
        registration: CmuxVaultAgentRegistration,
        fallbackCWD: String?
    ) -> RegisteredAgentJSONLMetadata {
        var metadata = RegisteredAgentJSONLMetadata()
        let needsNativeSessionID: Bool
        switch registration.sessionIdSource {
        case .argvOption:
            needsNativeSessionID = true
        case .piSessionFile, .grokSessionDirectory:
            needsNativeSessionID = false
        }
        let fieldParser = AgentSessionFieldParser()
        let historyParser = AgentHistoryRecordParser(fieldParser: fieldParser)
        ripgrepScanner.forEachJSONLine(url: url, maxBytes: 512 * 1024) { object in
            if metadata.sessionId == nil {
                metadata.sessionId = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLSessionIDKeys())
            }
            if metadata.cwd == nil {
                metadata.cwd = fieldParser.firstString(in: object, keys: historyParser.registeredJSONLCWDKeys())
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = fieldParser.firstString(in: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = fieldParser.firstString(in: object, keys: ["gitBranch", "branch"])
            }
            if metadata.title.isEmpty {
                metadata.title = fieldParser.firstTopLevelTitle(in: object) ?? ""
            }
            if metadata.title.isEmpty, let message = object["message"] as? [String: Any] {
                if fieldParser.shouldUseMessageAsTitle(message) {
                    metadata.title = fieldParser.firstText(in: message, keys: ["content", "text"]) ?? ""
                }
            }
            if metadata.title.isEmpty, let messages = object["messages"] as? [[String: Any]] {
                metadata.title = messages.compactMap { message in
                    fieldParser.shouldUseMessageAsTitle(message)
                        ? fieldParser.firstText(in: message, keys: ["content", "text"])
                        : nil
                }.first ?? ""
            }
            return !metadata.title.isEmpty
                && metadata.cwd != nil
                && metadata.branch != nil
                && (!needsNativeSessionID || metadata.sessionId != nil)
        }
        if case .piSessionFile = registration.sessionIdSource, metadata.cwd == nil {
            metadata.cwd = fallbackCWD ?? historyParser.piCWDInferred(from: url)
        }
        return metadata
    }
}
