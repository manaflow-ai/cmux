// SPDX-License-Identifier: GPL-3.0-or-later
public import CmuxNextComputerUse

/// Computer Use sessions in cmux Helper's worker: the File menu's and the menu bar's Computer Use
/// actions. The worker reports no per-session activity to the app, so no session is listed and
/// Stop ends every grant (`revoke_sessions`).
@MainActor
public final class CmuxHelperComputerUseSessions: ComputerUseSessionControlling {
    private let helper: CmuxHelperService
    private let ready: @MainActor () throws -> Void
    private let refused: @MainActor (any Error) -> any Error

    /// - Parameters:
    ///   - helper: cmux Helper, through the daemon.
    ///   - ready: Throws the reason when Computer Use does not run (off, turned off by policy).
    ///   - refused: The error to throw for a request the daemon refused.
    public init(helper: CmuxHelperService, ready: @escaping @MainActor () throws -> Void,
                refused: @escaping @MainActor (any Error) -> any Error) {
        self.helper = helper
        self.ready = ready
        self.refused = refused
    }

    public func liveSessions() async throws -> [ComputerUseLiveSession] {
        try ready()
        return []
    }

    /// No session is listed, so one session's Stop ends every grant.
    public func stop(_ id: String) async throws {
        try await stopAll()
    }

    public func stopAll() async throws {
        try ready()
        do { try await helper.stopComputerUseSessions() } catch { throw refused(error) }
    }

    public func raiseWindow(_ id: String) async throws {
        try ready()
        throw refused(CmuxHelperError.refused("no Computer Use session is listed"))
    }
}
