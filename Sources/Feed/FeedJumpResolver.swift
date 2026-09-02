import CmuxFoundation
import Foundation

/// Resolves Feed workstream identities to the cmux surface recorded by an
/// agent hook session.
///
/// The compatibility helpers are nonisolated and value-only; production Feed
/// ingress uses ``FeedSessionStoreLookup`` so filesystem work stays actor-owned.
nonisolated enum FeedJumpResolver {
    private static let hookSessionFileSuffix = "-hook-sessions.json"

    struct Target: Equatable, Hashable, Sendable {
        let workspaceId: String
        let surfaceId: String
    }

    /// Resolves both the current versioned identity and legacy hyphenated
    /// identities. Legacy resolution succeeds only when all matching split
    /// candidates point at one unique target; conflicting matches fail closed.
    ///
    /// - Parameters:
    ///   - workstreamID: The wire `workstream_id` value.
    ///   - homeDirectory: The home directory containing `.cmuxterm`. Injected
    ///     for behavior tests; production callers use the current user's home.
    /// - Returns: The recorded target, or `nil` when the id is malformed,
    ///   missing, or ambiguous.
    static func resolve(
        _ workstreamID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Target? {
        if let versioned = FeedWorkstreamIdentifier(rawValue: workstreamID) {
            return lookup(
                agent: versioned.agentID,
                sessionId: versioned.sessionID,
                homeDirectory: homeDirectory
            )
        }

        return resolveLegacy(
            workstreamID,
            homeDirectory: homeDirectory,
            agentIDs: availableAgentIDs(homeDirectory: homeDirectory)
        )
    }

    /// Resolves a legacy id against a caller-owned agent-file index.
    static func resolveLegacy(
        _ workstreamID: String,
        homeDirectory: URL,
        agentIDs: [String]
    ) -> Target? {
        var sessionsByAgent: [String: [String: Target]] = [:]
        let matches = legacyCandidates(
            for: workstreamID,
            agentIDs: agentIDs
        ).compactMap { candidate -> Target? in
            if sessionsByAgent[candidate.agent] == nil {
                sessionsByAgent[candidate.agent] = loadSessions(
                    agent: candidate.agent,
                    homeDirectory: homeDirectory
                )
            }
            return sessionsByAgent[candidate.agent]?[candidate.sessionID]
        }
        let uniqueMatches = Set(matches)
        return uniqueMatches.count == 1 ? uniqueMatches.first : nil
    }

    /// Looks up one exact agent/session pair in the hook-session store.
    ///
    /// This method is nonisolated because it is called by the socket worker
    /// and by ``FeedSessionStoreLookup``. It never mutates shared state.
    static func lookup(
        agent: String,
        sessionId: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Target? {
        guard isSafePathComponent(agent), !sessionId.isEmpty else { return nil }
        return loadSessions(agent: agent, homeDirectory: homeDirectory)?[sessionId]
    }

    /// Returns every possible legacy agent/session split. Keeping this pure
    /// makes the compatibility behavior easy to exercise without disk I/O.
    static func legacyCandidates(
        for workstreamID: String
    ) -> [(agent: String, sessionID: String)] {
        guard !workstreamID.isEmpty else { return [] }
        return workstreamID.indices.compactMap { index in
            guard workstreamID[index] == "-",
                  index > workstreamID.startIndex else { return nil }
            let sessionStart = workstreamID.index(after: index)
            guard sessionStart < workstreamID.endIndex else { return nil }
            let agent = String(workstreamID[..<index])
            let sessionID = String(workstreamID[sessionStart...])
            guard isSafePathComponent(agent), !sessionID.isEmpty else { return nil }
            return (agent: agent, sessionID: sessionID)
        }
    }

    private static func legacyCandidates(
        for workstreamID: String,
        agentIDs: some Collection<String>
    ) -> [(agent: String, sessionID: String)] {
        agentIDs.compactMap { agent in
            guard isSafePathComponent(agent) else { return nil }
            let prefix = agent + "-"
            guard workstreamID.hasPrefix(prefix) else { return nil }
            let sessionID = String(workstreamID.dropFirst(prefix.count))
            guard !sessionID.isEmpty else { return nil }
            return (agent: agent, sessionID: sessionID)
        }
    }

    static func availableAgentIDs(homeDirectory: URL) -> [String] {
        let directory = homeDirectory.appendingPathComponent(
            ".cmuxterm",
            isDirectory: true
        )
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return []
        }
        return names.compactMap { name in
            guard name.hasSuffix(hookSessionFileSuffix) else { return nil }
            let agent = String(name.dropLast(hookSessionFileSuffix.count))
            return isSafePathComponent(agent) ? agent : nil
        }
    }

    private static func loadSessions(
        agent: String,
        homeDirectory: URL
    ) -> [String: Target]? {
        guard isSafePathComponent(agent) else { return nil }
        let file = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agent)\(hookSessionFileSuffix)", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Stores have a consistent shape: top-level `sessions` dict keyed by
        // session id. Tolerate older flat layouts too.
        let rawSessions = (root["sessions"] as? [String: Any]) ?? root
        var sessions: [String: Target] = [:]
        for (sessionID, rawEntry) in rawSessions {
            guard let entry = rawEntry as? [String: Any],
                  let workspaceId = entry["workspaceId"] as? String,
                  let surfaceId = entry["surfaceId"] as? String,
                  !workspaceId.isEmpty,
                  !surfaceId.isEmpty else {
                continue
            }
            sessions[sessionID] = Target(workspaceId: workspaceId, surfaceId: surfaceId)
        }
        return sessions
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return !value.contains { character in
            character == "/" || character == "\\" || character.isNewline
        }
    }

    /// Dispatches a workspace-select + surface-focus intent through the
    /// existing cmux notification pathway.
    @MainActor
    static func focus(workspaceId: String, surfaceId: String) {
        NotificationCenter.default.post(
            name: .feedRequestFocus,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
            ]
        )
    }

    /// Dispatches a surface.send_text intent for the agent's terminal.
    @MainActor
    static func sendText(workspaceId: String, surfaceId: String, text: String) {
        NotificationCenter.default.post(
            name: .feedRequestSendText,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "surfaceId": surfaceId,
                "text": text,
            ]
        )
    }
}

/// Serializes hook-session reads for UI-originated Feed actions.
///
/// The actor owns only the filesystem lookup boundary; it returns immutable
/// ``FeedJumpResolver.Target`` values to its caller and never owns UI state.
actor FeedSessionStoreLookup {
    private let homeDirectory: URL
    private var indexedAgentIDs: [String]?
    private var indexedDirectoryModificationDate: Date?

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func resolve(_ workstreamID: String) -> FeedJumpResolver.Target? {
        if let versioned = FeedWorkstreamIdentifier(rawValue: workstreamID) {
            return FeedJumpResolver.lookup(
                agent: versioned.agentID,
                sessionId: versioned.sessionID,
                homeDirectory: homeDirectory
            )
        }
        guard let agentIDs = agentIDsForCurrentDirectory() else { return nil }
        return FeedJumpResolver.resolveLegacy(
            workstreamID,
            homeDirectory: homeDirectory,
            agentIDs: agentIDs
        )
    }

    /// Returns the cached hook-session file index, refreshing only when the
    /// directory's modification signal changes. Session contents are still
    /// read per candidate, so updates within an existing file are immediate.
    private func agentIDsForCurrentDirectory() -> [String]? {
        let directory = homeDirectory.appendingPathComponent(
            ".cmuxterm",
            isDirectory: true
        )
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: directory.path
        ),
        let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        if let indexedAgentIDs,
           indexedDirectoryModificationDate == modified {
            return indexedAgentIDs
        }
        let refreshed = FeedJumpResolver.availableAgentIDs(homeDirectory: homeDirectory)
        indexedAgentIDs = refreshed
        indexedDirectoryModificationDate = modified
        return refreshed
    }
}

extension Notification.Name {
    static let feedRequestFocus = Notification.Name("cmux.feedRequestFocus")
    static let feedRequestSendText = Notification.Name("cmux.feedRequestSendText")
}
