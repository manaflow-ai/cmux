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

    private struct GrokSessionMetadata {
        var title: String = ""
        var model: String?
        var permissionMode: String?
        var sandboxMode: String?
        var branch: String?
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
        let locator = GrokSessionLocator(homeDirectory: homeDirectory, environment: environment)
        let observedGrokHomes = locator.observedGrokHomes(
            hookStoreFileURL: RestorableAgentKind.grok.hookStoreFileURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            fileManager: fileManager
        )
        let roots = locator.sessionRoots(
            sessionDirectory: registration.sessionDirectory,
            cwdFilter: cwdFilter,
            observedGrokHomes: observedGrokHomes
        )
        guard !roots.isEmpty else { return [] }
        let fm = fileManager

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool, root: GrokSessionRoot)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepMatchingPaths(
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
                guard fileContains(candidate.url, needle: needle) else { continue }
            }

            let sessionDirectory = candidate.url.deletingLastPathComponent()
            let projectDirectory = sessionDirectory.deletingLastPathComponent().lastPathComponent
            let cwd = GrokSessionLocator.workingDirectory(fromProjectDirectoryName: projectDirectory)
            if let cwdFilter,
               GrokSessionLocator.normalizedWorkingDirectory(cwd)
                != GrokSessionLocator.normalizedWorkingDirectory(cwdFilter) {
                continue
            }

            let metadata = extractGrokSessionMetadata(url: candidate.url)
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

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepMatchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") else {
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
                guard fileContains(candidate.url, needle: needle) else { continue }
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

            historyURL.forEachJSONLine(maxBytes: Int.max) { object in
                if Task.isCancelled { return true }
                guard let sessionId = RovoDevMetadataFields.firstString(from: object, keys: antigravitySessionIDKeys()) else {
                    return false
                }
                let cwd = RovoDevMetadataFields.firstString(from: object, keys: registeredJSONLCWDKeys())
                if let cwdFilter, cwd != cwdFilter { return false }

                let title = SessionJSONLMetadataReader.antigravityHistoryTitle(in: object) ?? ""
                guard SessionJSONLMetadataReader.antigravityHistoryMatchesNeedle(
                    needle: needle,
                    sessionId: sessionId,
                    title: title,
                    cwd: cwd
                ) else {
                    return false
                }

                let modified = SessionJSONLMetadataReader.antigravityHistoryModifiedDate(in: object, fallback: fallbackModified)
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
            return GrokSessionLocator()
                .sessionRoots(sessionDirectory: registration.sessionDirectory, cwdFilter: cwdFilter)
                .map(\.sessionsRoot)
        }
        guard let root = registration.sessionDirectory.map({ ($0 as NSString).expandingTildeInPath }) else {
            return []
        }
        if case .piSessionFile = registration.sessionIdSource,
           let cwdFilter,
           let projectDirectory = PiSessionLocator.projectDirectoryName(for: cwdFilter) {
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

    nonisolated private static func extractGrokSessionMetadata(url: URL) -> GrokSessionMetadata {
        var metadata = GrokSessionMetadata()
        var remainingBranchProbeLines: Int?
        url.forEachJSONLine(maxBytes: 512 * 1024) { object in
            if metadata.title.isEmpty {
                metadata.title = SessionJSONLMetadataReader.grokTitle(in: object) ?? ""
            }
            if metadata.model == nil {
                metadata.model = RovoDevMetadataFields.firstString(from: object, keys: ["model", "modelId", "modelID", "model_id"])
                    ?? RovoDevMetadataFields.firstString(
                        from: object["message"] as? [String: Any] ?? [:],
                        keys: ["model", "modelId", "modelID", "model_id"]
                    )
            }
            if metadata.permissionMode == nil {
                metadata.permissionMode = RovoDevMetadataFields.firstString(
                    from: object,
                    keys: ["permissionMode", "permission_mode", "approvalPolicy", "approval_policy"]
                )
            }
            if metadata.sandboxMode == nil {
                metadata.sandboxMode = RovoDevMetadataFields.firstString(
                    from: object,
                    keys: ["sandboxMode", "sandbox_mode", "sandbox"]
                )
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = RovoDevMetadataFields.firstString(from: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = RovoDevMetadataFields.firstString(from: object, keys: ["gitBranch", "branch"])
            }
            let hasStableMetadata = !metadata.title.isEmpty
                && metadata.model != nil
                && metadata.permissionMode != nil
                && metadata.sandboxMode != nil
            guard hasStableMetadata else { return false }
            guard metadata.branch == nil else { return true }
            remainingBranchProbeLines = (remainingBranchProbeLines ?? 32) - 1
            return (remainingBranchProbeLines ?? 0) <= 0
        }
        return metadata
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
        url.forEachJSONLine(maxBytes: 512 * 1024) { object in
            if metadata.sessionId == nil {
                metadata.sessionId = RovoDevMetadataFields.firstString(from: object, keys: registeredJSONLSessionIDKeys())
            }
            if metadata.cwd == nil {
                metadata.cwd = RovoDevMetadataFields.firstString(from: object, keys: registeredJSONLCWDKeys())
            }
            if metadata.branch == nil, let git = object["git"] as? [String: Any] {
                metadata.branch = RovoDevMetadataFields.firstString(from: git, keys: ["branch", "gitBranch"])
            }
            if metadata.branch == nil {
                metadata.branch = RovoDevMetadataFields.firstString(from: object, keys: ["gitBranch", "branch"])
            }
            if metadata.title.isEmpty {
                metadata.title = SessionJSONLMetadataReader.firstTopLevelTitle(in: object) ?? ""
            }
            if metadata.title.isEmpty, let message = object["message"] as? [String: Any] {
                if SessionJSONLMetadataReader.shouldUseMessageAsTitle(message) {
                    metadata.title = SessionJSONLMetadataReader.firstText(in: message, keys: ["content", "text"]) ?? ""
                }
            }
            if metadata.title.isEmpty, let messages = object["messages"] as? [[String: Any]] {
                metadata.title = messages.compactMap { message in
                    SessionJSONLMetadataReader.shouldUseMessageAsTitle(message)
                        ? SessionJSONLMetadataReader.firstText(in: message, keys: ["content", "text"])
                        : nil
                }.first ?? ""
            }
            return !metadata.title.isEmpty
                && metadata.cwd != nil
                && metadata.branch != nil
                && (!needsNativeSessionID || metadata.sessionId != nil)
        }
        if case .piSessionFile = registration.sessionIdSource, metadata.cwd == nil {
            metadata.cwd = fallbackCWD ?? piCWDInferred(from: url)
        }
        return metadata
    }

    nonisolated private static func registeredJSONLCWDKeys() -> [String] {
        ["cwd", "workingDirectory", "workspacePath", "workspace", "projectPath", "directory"]
    }

    nonisolated private static func registeredJSONLSessionIDKeys() -> [String] {
        ["sessionId", "session_id", "id"]
    }

    nonisolated private static func antigravitySessionIDKeys() -> [String] {
        ["conversationId", "conversation_id", "sessionId", "session_id", "id"]
    }

    nonisolated private static func fileContains(_ url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let overlapLimit = max(needle.utf8.count * 4, 4 * 1024)
        var carry = Data()
        while !Task.isCancelled {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }

            var buffer = carry
            buffer.append(chunk)
            let text = String(decoding: buffer, as: UTF8.self)
            if text.range(of: needle, options: [.caseInsensitive, .literal]) != nil {
                return true
            }
            carry = buffer.count > overlapLimit ? Data(buffer.suffix(overlapLimit)) : buffer
        }
        return false
    }

    nonisolated private static func piCWDInferred(from url: URL) -> String? {
        let directoryName = url.deletingLastPathComponent().lastPathComponent
        guard directoryName.hasPrefix("--"), directoryName.hasSuffix("--"), directoryName.count > 4 else {
            return nil
        }
        let body = String(directoryName.dropFirst(2).dropLast(2))
        guard !body.isEmpty else { return nil }
        let candidate = "/" + body.replacingOccurrences(of: "-", with: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return candidate
    }
}
