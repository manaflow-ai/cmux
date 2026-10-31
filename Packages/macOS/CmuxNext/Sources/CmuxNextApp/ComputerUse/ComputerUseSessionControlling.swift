import CmuxNextComputerUse

/// The live Computer Use sessions on this Mac and the user's stop: the CUA
/// host in the App (``CuaComputerUseSessions``), a fake in tests.
@MainActor
protocol ComputerUseSessionControlling: AnyObject {
    /// The live sessions, newest action first.
    func liveSessions() async throws -> [ComputerUseLiveSession]
    /// Stops session `id` as the user (`activity_session_stop`, host-authenticated).
    func stop(_ id: String) async throws
}
