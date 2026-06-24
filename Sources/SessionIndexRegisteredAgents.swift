import CMUXAgentLaunch
import CmuxFoundation
import Foundation

extension SessionIndexStore {
    /// Resolves the pure, registration-decoupled session-layout pieces for
    /// registered agents (roots, candidate files, transcript metadata). The
    /// loaders below map each registration onto the resolver's primitive inputs
    /// and assemble the resulting `SessionEntry` values app-side.
    nonisolated static let registeredAgentResolver = RegisteredAgentSessionResolver(
        ripgrepScanner: ripgrepScanner,
        searchMaxFiles: searchMaxFiles
    )

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
                        contentsOf: registeredAgentResolver.enumerateGrokHistoryCandidates(root: root, fileManager: fileManager).map {
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
                    contentsOf: registeredAgentResolver.enumerateGrokHistoryCandidates(root: root, fileManager: fileManager).map {
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
        let roots = registeredAgentResolver.registeredSessionRoots(
            kind: registration.sessionIdSource.registeredAgentKind,
            sessionDirectory: registration.sessionDirectory,
            cwdFilter: cwdFilter
        )
        guard !roots.isEmpty else { return [] }
        let fm = FileManager.default
        let historyParser = AgentHistoryRecordParser()

        var candidates: [(url: URL, modified: Date, prefilteredByRipgrep: Bool)] = []
        if !needle.isEmpty {
            for root in roots {
                guard let rgPaths = await ripgrepScanner.matchingPaths(needle: needle, root: root, fileGlob: "*.jsonl") else {
                    candidates.append(
                        contentsOf: registeredAgentResolver.enumerateRegisteredJSONLCandidates(root: root).map {
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
                    contentsOf: registeredAgentResolver.enumerateRegisteredJSONLCandidates(root: root).map {
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

            let metadata = registeredAgentResolver.extractRegisteredJSONLMetadata(
                url: candidate.url,
                kind: registration.sessionIdSource.registeredAgentKind,
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
        let roots = registeredAgentResolver.registeredSessionRoots(
            kind: registration.sessionIdSource.registeredAgentKind,
            sessionDirectory: registration.sessionDirectory,
            cwdFilter: cwdFilter
        )
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

    /// The registration with its `resumeCommand` prefixed by the captured
    /// `GROK_HOME`, or the registration unchanged when no prefix is needed.
    ///
    /// Forwards the prefix computation to ``RegisteredAgentSessionResolver`` (which
    /// owns the shell quoting + skip rules) and applies the result to a copy of the
    /// app-side `CmuxVaultAgentRegistration`, the one piece the package cannot
    /// construct.
    nonisolated private static func registrationWithGrokHomePrefix(
        _ registration: CmuxVaultAgentRegistration,
        grokHome: String?
    ) -> CmuxVaultAgentRegistration {
        guard let prefixed = registeredAgentResolver.grokHomePrefixedResumeCommand(
            registration.resumeCommand,
            grokHome: grokHome
        ) else {
            return registration
        }
        var copy = registration
        copy.resumeCommand = prefixed
        return copy
    }
}

extension CmuxVaultAgentSessionIDSource {
    /// The package-owned ``RegisteredAgentSessionIDKind`` mirror of this app-side
    /// session-id-source, so the registration-decoupled resolver can branch on
    /// layout without seeing the app's Codable enum.
    var registeredAgentKind: RegisteredAgentSessionIDKind {
        switch self {
        case .argvOption:
            return .argvOption
        case .piSessionFile:
            return .piSessionFile
        case .grokSessionDirectory:
            return .grokSessionDirectory
        }
    }
}
