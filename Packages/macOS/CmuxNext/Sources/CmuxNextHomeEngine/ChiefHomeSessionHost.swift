public import CmuxNextAgentPane
public import Foundation

/// The pane host of a tab whose record names a Chief home other than the app's (#25262): its chat
/// opens from that home's acpmux when that home keeps it (``AcpmuxChiefSessionRouter``), else from
/// `fallback`, this Mac's (a home no longer here, a session NIGHTLY's Chief ran on the app's
/// acpmux). Never "belongs to another machine": the home is this Mac's.
public nonisolated struct ChiefHomeSessionHost: AgentPaneHostProviding {
    let host: String
    let homes: ChiefHomeDirectory
    let fallback: any AgentPaneHostProviding

    public init(host: String, homes: ChiefHomeDirectory, fallback: any AgentPaneHostProviding) {
        self.host = host
        self.homes = homes
        self.fallback = fallback
    }

    private func resolved() async -> any AgentPaneHostProviding {
        await homes.router(for: host, fallback: fallback) ?? fallback
    }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await resolved().handshake(sessionId: sessionId)
    }

    public func reconnectHandshake(sessionId: String?) async throws -> AgentPaneHandshake {
        try await resolved().reconnectHandshake(sessionId: sessionId)
    }

    public func prewarm() async throws {
        try await fallback.prewarm()
    }

    public func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
        try await resolved().sessionFolder(sessionId: sessionId)
    }

    public func putFile(sessionId: String, name: String, data: Data) async throws -> String {
        try await resolved().putFile(sessionId: sessionId, name: name, data: data)
    }

    public func putFile(sessionId: String, name: String, file: URL) async throws -> String {
        try await resolved().putFile(sessionId: sessionId, name: name, file: file)
    }

    /// Restart acpmux replaces this Mac's daemon only (as ``AcpmuxChiefSessionRouter``).
    public func restartAcpmux(owner: AcpmuxSocketOwner) async -> Bool {
        await fallback.restartAcpmux(owner: owner)
    }

    /// Restart agent service goes where the pane's handshake goes (``AcpmuxChiefSessionRouter``).
    public func restartStuckAcpmux(sessionId: String?) async -> Bool {
        await resolved().restartStuckAcpmux(sessionId: sessionId)
    }
}
