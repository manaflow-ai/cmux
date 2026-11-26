/// Awaits `work` from a `@concurrent` frame, so the caller gets its own isolation back on return.
///
/// A main-actor method that awaits a *stored* async closure of a plain (`nonisolated(nonsending)`)
/// type holding a `@concurrent` function (a CLI runner injected through `init`) can resume on a
/// cooperative thread with the Swift 6.2 toolchains the app ships with; the next main-actor
/// access then traps in `dispatch_assert_queue` (https://github.com/manaflow-ai/cmux/issues/54632).
/// Annotating the stored type `@concurrent` did not help on those toolchains. Awaiting through
/// this function leaves every hop of the closure inside a `@concurrent` frame; returning from it
/// is an ordinary call into a `@concurrent` function, whose hop back the compiler emits.
///
/// ```swift
/// let reply = try? await awaitConcurrently { try await runCLI(cli, ["--json", "agent", "hook", "status"]) }
/// ```
///
/// - Parameter work: The stored closure's call; it runs off the caller's actor.
/// - Returns: What `work` returned.
/// - Throws: What `work` threw.
@concurrent public nonisolated func awaitConcurrently<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
    try await work()
}
