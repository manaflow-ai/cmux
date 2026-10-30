public import Foundation

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
    /// When that daemon does not answer (stopped, starting, or slower than the deadline), a
    /// session it keeps on disk under `sessionsHome` (`<ACPMUX_HOME>/sessions/<id>`) is still
    /// its own: the tab attaches there, never to a daemon that lacks the chat (which says
    /// "This chat isn't available").
    ///
    /// - Parameter sessionsHome: the Chief home's `ACPMUX_HOME`; defaults to `environment`'s.
    public init(local: any AgentPaneHostProviding, chief: any AgentPaneHostProviding,
                chiefEnvironment environment: AcpmuxEnvironment?, sessionsHome: URL? = nil, parentTag: String) {
        let socket = environment?.socketPath
        let kept = sessionsHome ?? environment?.home
        self.init(local: local, chief: chief) { session in
            if let socket, FileManager.default.fileExists(atPath: socket),
               let listing = try? await AcpmuxStatusClient.sessions(socketPath: socket, deadline: .seconds(2)) {
                return Self.owns(listing.value, session: session, parentTag: parentTag)
            }
            return Self.keeps(session: session, home: kept)
        }
    }

    /// Whether acpmux home `home` keeps session `session` on disk (`sessions/<id>`).
    public static func keeps(session: String, home: URL?) -> Bool {
        guard let home, !session.isEmpty, session != ".", session != "..", !session.contains("/") else { return false }
        var directory: ObjCBool = false
        let path = home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(session).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Whether `_acpmux/sessions` result `listing` has `session` tagged `mux.parent` = `parentTag`.
    public static func owns(_ listing: [String: Any], session: String, parentTag: String) -> Bool {
        let rows = listing["sessions"] as? [[String: Any]] ?? []
        return rows.contains { row in
            row["sessionId"] as? String == session && (row["tags"] as? [String: Any])?["mux.parent"] as? String == parentTag
        }
    }

    /// Whichever of the two hosts listens on `socket`: the pane's socket names its daemon.
    public func answerEnvironment(socket: String) async -> AcpmuxEnvironment? {
        if let local = await local.answerEnvironment(socket: socket) { return local }
        return await chief.answerEnvironment(socket: socket)
    }

    private func host(for session: String?) async -> any AgentPaneHostProviding {
        guard let session, await chiefOwns(session) else { return local }
        return chief
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await routed(sessionId) { try await $0.handshake(sessionId: sessionId) }
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await routed(sessionId) { try await $0.reconnectHandshake(sessionId: sessionId) }
    }

    /// A handshake on the host that runs `session`. A refusal from the Chief home's acpmux offers
    /// no Restart acpmux: that only replaces this Mac's own daemon (``restartAcpmux(owner:)``),
    /// never the Chief home's.
    private func routed(_ session: String?,
                        _ body: (any AgentPaneHostProviding) async throws -> AgentPaneHandshake) async throws -> AgentPaneHandshake {
        guard let session, await chiefOwns(session) else { return try await body(local) }
        do {
            return try await body(chief)
        } catch AgentPaneHostError.daemonRefused(let holder, let socketPath, let reason, let executable, _?) {
            throw AgentPaneHostError.daemonRefused(holder: holder, socketPath: socketPath, reason: reason,
                                                   executable: executable, owner: nil)
        }
    }

    public func prewarm() async throws {
        try await local.prewarm()
    }

    /// The folder of `sessionId` from the host that owns it (the chief's or
    /// this Mac's acpmux), so a commit or push runs in that session's folder.
    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
        try await host(for: sessionId).sessionFolder(sessionId: sessionId)
    }

    /// Restart acpmux replaces the daemon on this Mac's socket, never the Chief home's.
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool {
        await local.restartAcpmux(owner: owner)
    }

    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        try await host(for: sessionId).putFile(sessionId: sessionId, name: name, data: data)
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        try await host(for: sessionId).putFile(sessionId: sessionId, name: name, file: file)
    }
}
