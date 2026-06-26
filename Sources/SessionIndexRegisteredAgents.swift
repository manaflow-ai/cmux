import CMUXAgentLaunch
import CmuxFoundation
import Foundation

struct GrokSessionRoot: Sendable, Hashable {
    let sessionsRoot: String
    let grokHomeForResume: String?
}

private struct GrokHookObservedSessionStoreFile: Decodable {
    var sessions: [String: GrokHookObservedSessionRecord]

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(
            [String: GrokHookObservedSessionRecord].self,
            forKey: .sessions
        ) ?? [:]
    }
}

private struct GrokHookObservedSessionRecord: Decodable {
    var launchCommand: GrokHookObservedLaunchCommand?
}

private struct GrokHookObservedLaunchCommand: Decodable {
    var environment: [String: String]?
}

enum GrokSessionLocator {
    static func defaultSessionsRoot(homeDirectory: String = NSHomeDirectory()) -> String {
        let standardizedHome = expandTilde(homeDirectory, homeDirectory: homeDirectory)
        return ((standardizedHome as NSString).appendingPathComponent(".grok") as NSString)
            .appendingPathComponent("sessions")
    }

    static func encodedSessionCWD(_ cwd: String) -> String {
        var encoded = ""
        for byte in cwd.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
            if isUnreserved {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    static func workingDirectory(fromProjectDirectoryName name: String) -> String? {
        let decoded = name.removingPercentEncoding ?? name
        return normalizedWorkingDirectory(decoded)
    }

    static func normalizedWorkingDirectory(_ value: String?) -> String? {
        let trimmed = normalized(value)
        return trimmed.map { ($0 as NSString).standardizingPath }
    }

    static func encodedSessionCWDs(for cwd: String) -> [String] {
        guard let rawCwd = normalized(cwd) else {
            return []
        }
        var seen = Set<String>()
        return [rawCwd, (rawCwd as NSString).standardizingPath]
            .map(encodedSessionCWD)
            .filter { seen.insert($0).inserted }
    }

    static func sessionRoot(
        registration: CmuxVaultAgentRegistration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> GrokSessionRoot {
        let rawRoot: String
        let configuredRoot = normalized(registration.sessionDirectory)
        let configuredIsDefault = configuredRoot.map {
            expandTilde($0, homeDirectory: homeDirectory)
                == (defaultSessionsRoot(homeDirectory: homeDirectory) as NSString).standardizingPath
        } ?? false
        if let grokHome = normalized(environment["GROK_HOME"]),
           configuredRoot == nil || configuredIsDefault {
            rawRoot = (grokHome as NSString).appendingPathComponent("sessions")
        } else if let configured = configuredRoot {
            rawRoot = configured
        } else {
            rawRoot = defaultSessionsRoot(homeDirectory: homeDirectory)
        }
        let sessionsRoot = expandTilde(rawRoot, homeDirectory: homeDirectory)
        let grokHome = grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot(homeDirectory: homeDirectory)
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    static func sessionRoots(
        registration: CmuxVaultAgentRegistration,
        cwdFilter: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        observedGrokHomes: [String] = []
    ) -> [GrokSessionRoot] {
        let root = sessionRoot(
            registration: registration,
            environment: environment,
            homeDirectory: homeDirectory
        )
        var roots = [root]
        if registrationUsesDefaultGrokRoot(registration: registration, homeDirectory: homeDirectory) {
            for grokHome in observedGrokHomes {
                guard let candidate = sessionRoot(
                    grokHome: grokHome,
                    homeDirectory: homeDirectory
                ) else {
                    continue
                }
                roots.append(candidate)
            }
            roots = deduplicatedSessionRoots(roots)
        }
        guard let cwdFilter = normalized(cwdFilter) else {
            return roots
        }
        let scopedRoots = roots.flatMap { root in
            encodedSessionCWDs(for: cwdFilter).map { encodedCwd in
                let scopedRoot = (root.sessionsRoot as NSString).appendingPathComponent(encodedCwd)
                return GrokSessionRoot(sessionsRoot: scopedRoot, grokHomeForResume: root.grokHomeForResume)
            }
        }
        return deduplicatedSessionRoots(scopedRoots)
    }

    static func observedGrokHomes(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        let storeURL = RestorableAgentKind.grok.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        guard fileManager.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let state = try? JSONDecoder().decode(GrokHookObservedSessionStoreFile.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        var homes: [String] = []
        for record in state.sessions.values {
            guard let rawHome = normalized(record.launchCommand?.environment?["GROK_HOME"]) else {
                continue
            }
            let home = expandTilde(rawHome, homeDirectory: homeDirectory)
            guard seen.insert(home).inserted else { continue }
            homes.append(home)
        }
        return homes
    }

    private static func grokHomeForResume(sessionsRoot: String, defaultSessionsRoot: String) -> String? {
        let standardizedRoot = (sessionsRoot as NSString).standardizingPath
        let standardizedDefault = (defaultSessionsRoot as NSString).standardizingPath
        guard standardizedRoot != standardizedDefault else { return nil }
        guard (standardizedRoot as NSString).lastPathComponent == "sessions" else { return nil }
        return (standardizedRoot as NSString).deletingLastPathComponent
    }

    private static func sessionRoot(grokHome: String, homeDirectory: String) -> GrokSessionRoot? {
        guard let normalizedHome = normalized(grokHome) else { return nil }
        let expandedHome = expandTilde(normalizedHome, homeDirectory: homeDirectory)
        let sessionsRoot = (expandedHome as NSString).appendingPathComponent("sessions")
        let grokHome = grokHomeForResume(
            sessionsRoot: sessionsRoot,
            defaultSessionsRoot: defaultSessionsRoot(homeDirectory: homeDirectory)
        )
        return GrokSessionRoot(sessionsRoot: sessionsRoot, grokHomeForResume: grokHome)
    }

    private static func registrationUsesDefaultGrokRoot(
        registration: CmuxVaultAgentRegistration,
        homeDirectory: String
    ) -> Bool {
        guard let configuredRoot = normalized(registration.sessionDirectory) else {
            return true
        }
        let expandedConfigured = expandTilde(configuredRoot, homeDirectory: homeDirectory)
        let expandedDefault = (defaultSessionsRoot(homeDirectory: homeDirectory) as NSString).standardizingPath
        return expandedConfigured == expandedDefault
    }

    private static func deduplicatedSessionRoots(_ roots: [GrokSessionRoot]) -> [GrokSessionRoot] {
        var seen = Set<String>()
        return roots.filter { root in
            seen.insert((root.sessionsRoot as NSString).standardizingPath).inserted
        }
    }

    private static func expandTilde(_ path: String, homeDirectory: String) -> String {
        let home = ((homeDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return ((home as NSString).appendingPathComponent(suffix) as NSString).standardizingPath
        }
        return ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

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
        let observedGrokHomes = GrokSessionLocator.observedGrokHomes(
            homeDirectory: homeDirectory,
            environment: environment,
            fileManager: fileManager
        )
        let roots = GrokSessionLocator.sessionRoots(
            registration: registration,
            cwdFilter: cwdFilter,
            environment: environment,
            homeDirectory: homeDirectory,
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
            return GrokSessionLocator.sessionRoots(registration: registration, cwdFilter: cwdFilter)
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
