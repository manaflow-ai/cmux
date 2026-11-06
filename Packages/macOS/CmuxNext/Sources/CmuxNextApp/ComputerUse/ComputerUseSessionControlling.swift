import CmuxNextComputerUse

/// The live Computer Use sessions on this Mac and the user's stop: cmux Remote's Computer Use
/// worker in the App (``RemoteComputerUseSessions``), a fake in tests.
@MainActor
protocol ComputerUseSessionControlling: AnyObject {
    /// The live sessions, newest action first.
    func liveSessions() async throws -> [ComputerUseLiveSession]
    /// Stops session `id` as the user.
    func stop(_ id: String) async throws
    /// Stops every agent session on this Mac (their grants end; the agents must ask again).
    func stopAll() async throws
}
