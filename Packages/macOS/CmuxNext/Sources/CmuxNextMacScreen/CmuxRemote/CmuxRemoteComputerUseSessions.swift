// SPDX-License-Identifier: GPL-3.0-or-later
public import CmuxNextComputerUse

/// Computer Use sessions in cmux Remote's worker, as its activity reports them (``CmuxRemoteComputerUseState``):
/// the File menu's and the menu bar's Computer Use actions. Stop ends one session (its calls are
/// refused with `stopped_by_person` until Resume), or every listed one and then every grant.
@MainActor
public final class CmuxRemoteComputerUseSessions: ComputerUseSessionControlling {
    private let remote: CmuxRemoteService
    private let ready: @MainActor () throws -> Void
    private let refused: @MainActor (any Error) -> any Error

    /// - Parameters:
    ///   - remote: cmux Remote, through the daemon.
    ///   - ready: Throws the reason when Computer Use does not run (off, turned off by policy).
    ///   - refused: The error to throw for a request cmux Remote refused.
    public init(remote: CmuxRemoteService, ready: @escaping @MainActor () throws -> Void,
                refused: @escaping @MainActor (any Error) -> any Error) {
        self.remote = remote
        self.ready = ready
        self.refused = refused
    }

    public func liveSessions() async throws -> [ComputerUseLiveSession] {
        try ready()
        return remote.computerUse.sessions.map(\.live)
    }

    public func stop(_ id: String) async throws {
        try ready()
        let label = remote.computerUse.sessions.first { $0.id == id }?.agent
        do { try await remote.computerUseSession(.stop, session: id, label: label) } catch { throw refused(error) }
    }

    /// Every listed session is stopped (its agent is told so), then every grant ends.
    public func stopAll() async throws {
        try ready()
        for session in remote.computerUse.sessions where !session.stopped {
            _ = try? await remote.computerUseSession(.stop, session: session.id, label: session.agent)
        }
        do { try await remote.stopComputerUseSessions() } catch { throw refused(error) }
    }

    public func raiseWindow(_ id: String) async throws {
        try ready()
        try await remote.computerUseSession(.raiseWindow, session: id)
    }
}
