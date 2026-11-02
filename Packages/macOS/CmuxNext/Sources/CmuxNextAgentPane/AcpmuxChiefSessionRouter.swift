public import Foundation

/// The pane host of a tab whose record names this Mac or this app's Chief home: a session the
/// Chief home's acpmux runs attaches there; any other session, and a new chat, attaches to this
/// Mac's acpmux. Subagent tabs made before the `chief:<home id>` host existed record this Mac's
/// host; this keeps them working with no record rewrite.
///
/// The Chief home's daemon is asked for the session itself (an exact `_acpmux/resolve`), never for
/// a tag: it runs more than the home's own Chief's subagents (#27934). A named Chief of the home
/// (`<home>/c/<id>`, `OPTCHAT_ACPMUX_SHARED`) runs its subagents there tagged with its own
/// `optchat-chief:<named id>`, a subagent's `acpmux new` chat there has no `mux.parent`, and the
/// Chief's spawn tool opens their workspaces with no host, so the tab records this Mac's. A tag
/// check sent each of those to this Mac's acpmux, which lacks the chat ("Can't find this chat").
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

    /// Asks the Chief home's acpmux (`environment`) whether it runs `session` itself (not a peer's
    /// row it mirrors). When that daemon does not answer (stopped, starting, or slower than the
    /// deadline) or does not have it loaded, a session it keeps on disk under `sessionsHome`
    /// (`<ACPMUX_HOME>/sessions/<id>`) is still its own: the tab attaches there, never to a daemon
    /// that lacks the chat (which says "This chat isn't available").
    ///
    /// - Parameter sessionsHome: the Chief home's `ACPMUX_HOME`; defaults to `environment`'s.
    public init(local: any AgentPaneHostProviding, chief: any AgentPaneHostProviding,
                chiefEnvironment environment: AcpmuxEnvironment?, sessionsHome: URL? = nil) {
        let socket = environment?.socketPath
        let kept = sessionsHome ?? environment?.home
        self.init(local: local, chief: chief) { session in
            if let socket, FileManager.default.fileExists(atPath: socket),
               await Self.runs(session, socketPath: socket) {
                return true
            }
            return Self.keeps(session: session, home: kept)
        }
    }

    /// Whether the daemon on `socketPath` runs `session` itself: its exact resolve names it, and not
    /// as a peer's row (resolve also reads the rows it mirrors from its peers). False when it has no
    /// such session or does not answer.
    static func runs(_ session: String, socketPath: String) async -> Bool {
        guard !session.isEmpty,
              let found = try? await AcpmuxStatusClient.sessionSummary(socketPath: socketPath, sessionId: session, deadline: .seconds(2))
        else { return false }
        return (found["peer"] as? String)?.isEmpty != false
    }

    /// Whether acpmux home `home` keeps session `session` on disk (`sessions/<id>`).
    public static func keeps(session: String, home: URL?) -> Bool {
        guard let home, !session.isEmpty, session != ".", session != "..", !session.contains("/") else { return false }
        var directory: ObjCBool = false
        let path = home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(session).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
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

    /// Restart agent service goes to the host the pane's handshake goes to: this Mac's own daemon
    /// for a local chat; the Chief home's host starts no daemon, so it stops none.
    public func restartStuckAcpmux(sessionId: String?) async -> Bool {
        await host(for: sessionId).restartStuckAcpmux(sessionId: sessionId)
    }

    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        try await host(for: sessionId).putFile(sessionId: sessionId, name: name, data: data)
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        try await host(for: sessionId).putFile(sessionId: sessionId, name: name, file: file)
    }
}
