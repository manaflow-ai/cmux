/// The live Computer Use sessions on this Mac and the user's stop: cmux Remote's Computer Use
/// worker in the App (`CmuxRemoteComputerUseSessions`), a fake in tests.
@MainActor
public protocol ComputerUseSessionControlling: AnyObject {
    /// The live sessions, newest action first.
    func liveSessions() async throws -> [ComputerUseLiveSession]
    /// Stops session `id` as the user: its in-flight call ends at its next step and every later call
    /// is refused with `stopped_by_person`, which tells the agent to ask the person.
    func stop(_ id: String) async throws
    /// Stops every agent session on this Mac (their grants end; the agents must ask again).
    func stopAll() async throws
    /// Raises the window session `id` works in to the front of its app (Show Window); the caller
    /// then brings the app forward.
    func raiseWindow(_ id: String) async throws
}

public extension ComputerUseSessionControlling {
    /// Stops the session one of `terminals` (comma-separated, a row's drive indicator's agent) started, else the
    /// newest live one; with no terminals or no live session, every session: the person's stop must not depend on a
    /// session list the host may not give (Stop Computer Use with no target, #37003).
    func stop(terminals: String?) async throws {
        let ids = Set((terminals ?? "").split(separator: ",").map(String.init))
        guard !ids.isEmpty, let picked = ComputerUseLiveSession.pick(try await liveSessions(), terminals: ids) else { return try await stopAll() }
        try await stop(picked.id)
    }
}
