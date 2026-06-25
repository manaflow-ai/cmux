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
        let historyParser = AgentHistoryRecordParser()

        var candidates = await registeredAgentResolver.gatherGrokHistoryCandidates(
            roots: roots,
            needle: needle,
            fileManager: fileManager
        )

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
        let historyParser = AgentHistoryRecordParser()

        var candidates = await registeredAgentResolver.gatherRegisteredJSONLCandidates(
            roots: roots,
            needle: needle
        )

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
        let entries = registeredAgentResolver.resolveAntigravityHistory(
            kind: registration.sessionIdSource.registeredAgentKind,
            sessionDirectory: registration.sessionDirectory,
            needle: needle,
            cwdFilter: cwdFilter
        )
        .map { entry in
            SessionEntry(
                id: "\(registration.id):\(entry.sessionId)",
                agent: .registered(RegisteredSessionAgent(registration: registration)),
                sessionId: entry.sessionId,
                title: entry.title,
                cwd: entry.cwd,
                gitBranch: nil,
                pullRequest: nil,
                modified: entry.modified,
                fileURL: entry.fileURL,
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
