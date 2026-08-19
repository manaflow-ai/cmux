import CmuxFoundation
import Foundation

/// Resolves Feed workstream identities to the cmux surface recorded by an
/// agent hook session.
///
/// Resolution is deliberately a synchronous, nonisolated operation so the
/// socket-worker ingress path can perform one bounded file read without
/// hopping through the main actor. UI callers use ``FeedSessionStoreLookup``
/// below, which owns the same operation behind an actor and therefore never
/// perform the read on the main actor.
nonisolated enum FeedJumpResolver {
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

        let matches = legacyCandidates(for: workstreamID).compactMap { candidate in
            lookup(
                agent: candidate.agent,
                sessionId: candidate.sessionID,
                homeDirectory: homeDirectory
            )
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
        let file = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("\(agent)-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Stores have a consistent shape: top-level `sessions` dict keyed by
        // session id. Tolerate older flat layouts too.
        let sessions: [String: Any]
        if let nested = root["sessions"] as? [String: Any] {
            sessions = nested
        } else {
            sessions = root
        }
        guard let entry = sessions[sessionId] as? [String: Any],
              let workspaceId = entry["workspaceId"] as? String,
              let surfaceId = entry["surfaceId"] as? String,
              !workspaceId.isEmpty,
              !surfaceId.isEmpty
        else { return nil }
        return Target(workspaceId: workspaceId, surfaceId: surfaceId)
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

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func resolve(_ workstreamID: String) -> FeedJumpResolver.Target? {
        FeedJumpResolver.resolve(workstreamID, homeDirectory: homeDirectory)
    }
}

extension Notification.Name {
    static let feedRequestFocus = Notification.Name("cmux.feedRequestFocus")
    static let feedRequestSendText = Notification.Name("cmux.feedRequestSendText")
}
