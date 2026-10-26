public import Foundation

/// Produces the handshake for a pane. The App picks the live acpmux host or
/// the mock; the pane never knows which.
public nonisolated protocol AgentPaneHostProviding: Sendable {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// Starts the daemon before a page is visible. Callers may treat this as
    /// best effort because the normal page handshake still reports failures.
    func prewarm() async throws
    /// The handshake for a page that lost its daemon. Starts one only after a
    /// crash, so a daemon the user stopped stays stopped.
    func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake
    /// The folder of the daemon's session `sessionId`, nil when it has none.
    /// Never starts a daemon.
    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder?
    /// Starts the agent of each session in `sessionIds` without a page (`_acpmux/warm`), so a
    /// relaunch resumes every chat tab, not only the ones shown. A session whose agent runs
    /// already, or whose folder has no Trust answer, is left as it is.
    func warm(sessionIds: [String]) async throws
    /// Saves a file the person dropped into session `sessionId` on the machine that runs it (an
    /// ssh peer's chat: on that peer) and answers its path there. Throws
    /// ``AgentPaneFilePutFailure``. Never starts a daemon.
    func putFile(sessionId: String, name: String, data: Data) async throws -> String
    func putFile(sessionId: String, name: String, file: URL) async throws -> String
    /// A person asked to restart acpmux from this app's own binary after a refusal named another
    /// binary on the socket (``AgentPaneHostError/daemonRefused(holder:socketPath:reason:executable:owner:)``
    /// with an owner): stops that daemon, keeping its sessions, so the next handshake starts this
    /// app's. Only while `owner`, the binary the refusal named, still holds the socket. True when
    /// it stopped.
    func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool
    /// The acpmux whose socket is `socket`, for an answer the host gives itself on the person's
    /// behalf (``AgentPaneAskAnswer``): nil when this host's daemon listens elsewhere, or it has none.
    func answerEnvironment(socket: String) async -> AcpmuxEnvironment?
}

extension AgentPaneHostProviding {
    /// Hosts without a daemon answer a reconnect like a first handshake.
    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await handshake(sessionId: sessionId)
    }

    public func prewarm() async throws {}

    /// Hosts without a daemon know no session folders.
    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }

    /// Hosts without a daemon run no agents.
    public func warm(sessionIds: [String]) async throws {}

    /// Hosts without a daemon have none to restart.
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool { false }

    /// Hosts without a daemon answer nothing themselves.
    public func answerEnvironment(socket: String) async -> AcpmuxEnvironment? { nil }

    /// Hosts without a daemon take no files.
    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        throw AgentPaneFilePutFailure.unsupported
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: file)
        }.value
        return try await putFile(sessionId: sessionId, name: name, data: data)
    }
}
