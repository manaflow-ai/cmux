/// What the mobile host needs from the Mac's task runner. The app implements
/// it over acpmux (`_acpmux/harnesses`, `_acpmux/models`, `session/new`,
/// `session/prompt`, `session/cancel`) and the workspace store
/// (`create-workspace`, with no argv, cwd or environment from the phone);
/// tests use a fake. The runner owns task records; the host only projects them.
public protocol MobileTaskRunner: Sendable {
    /// The harnesses this Mac offers, with models, efforts and unavailability.
    func agents() async throws -> [MobileAgent]
    /// Tasks this runner started.
    func tasks() async throws -> [MobileTask]
    /// Yields once per change batch (agents or tasks), until the subscriber stops.
    func changes() async -> AsyncStream<Void>
    /// Starts one agent session. Throws `MobileDaemonError` with a family code
    /// (`task.agent_unavailable`, `workspace.not_found`) on refusal.
    func dispatch(_ request: MobileTaskDispatch, context: MobileOpContext) async throws -> MobileTaskDispatchResult
    /// Cancels a running task (`task.not_found` when it is not this runner's).
    func cancel(task: String, context: MobileOpContext) async throws
}
