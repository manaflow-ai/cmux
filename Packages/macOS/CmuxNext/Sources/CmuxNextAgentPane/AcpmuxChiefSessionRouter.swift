import Foundation

/// The pane host of a tab whose record names this Mac: a session the Chief host started in its
/// home's acpmux (`mux.parent` = `optchat-chief:<home id>` in that one daemon's listing) attaches
/// there; any other session, and a new chat, attaches to this Mac's acpmux. Subagent tabs made
/// before the `chief:<home id>` host existed record this Mac's host; this keeps them working
/// with no record rewrite and no search of other daemons.
public nonisolated struct AcpmuxChiefSessionRouter: AgentPaneHostProviding {
    private let local: any AgentPaneHostProviding
    private let chief: any AgentPaneHostProviding
    private let chiefOwns: @Sendable (String) async -> Bool

    public init(local: any AgentPaneHostProviding, chief: any AgentPaneHostProviding,
                chiefOwns: @escaping @Sendable (String) async -> Bool) {
        self.local = local
        self.chief = chief
        self.chiefOwns = chiefOwns
    }

    /// Asks the Chief home's acpmux (`environment`) whether it runs `session` for `parentTag`.
    public init(local: any AgentPaneHostProviding, chief: any AgentPaneHostProviding,
                chiefEnvironment environment: AcpmuxEnvironment?, parentTag: String) {
        let socket = environment?.socketPath
        self.init(local: local, chief: chief) { session in
            guard let socket, FileManager.default.fileExists(atPath: socket),
                  let listing = try? await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)) else { return false }
            return Self.owns(listing.value, session: session, parentTag: parentTag)
        }
    }

    /// Whether `_acpmux/sessions` result `listing` has `session` tagged `mux.parent` = `parentTag`.
    public static func owns(_ listing: [String: Any], session: String, parentTag: String) -> Bool {
        let rows = listing["sessions"] as? [[String: Any]] ?? []
        return rows.contains { row in
            row["sessionId"] as? String == session && (row["tags"] as? [String: Any])?["mux.parent"] as? String == parentTag
        }
    }

    private func host(for session: String?) async -> any AgentPaneHostProviding {
        guard let session, await chiefOwns(session) else { return local }
        return chief
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await host(for: sessionId).handshake(sessionId: sessionId)
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await host(for: sessionId).reconnectHandshake(sessionId: sessionId)
    }

    public func prewarm() async throws {
        try await local.prewarm()
    }
}
