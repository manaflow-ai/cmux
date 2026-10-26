/// What ``BackgroundWork/shutdown()`` does with an item, as Chrome's `TaskShutdownBehavior`.
public enum ShutdownBehavior: Sendable {
    /// Keep running if it has started; drop it if it has not. Quit does not wait for it.
    case continueOnShutdown
    /// Drop it if it has not started (a ``BackgroundWork/run(_:mayBlock:shutdown:fileID:line:_:)`` caller gets
    /// `CancellationError`); quit does not wait for a started one, and cancels a started
    /// ``BackgroundWork/task(_:shutdown:fileID:line:_:)``. The default: reads and anything a later launch redoes.
    case skipOnShutdown
    /// Quit waits for it: a save whose loss loses a person's data. Only for one bounded write (< 50 ms, an
    /// atomic replace), never a scan, a migration or a network call: Debug records one that runs longer than
    /// ``BackgroundWork/blockShutdownLimit`` (``BackgroundWork/blockShutdownOverruns``).
    case blockShutdown
}
