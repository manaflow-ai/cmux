/// What ``BackgroundWork/shutdown()`` does with an item, as Chrome's `TaskShutdownBehavior`.
public enum ShutdownBehavior: Sendable {
    /// Keep running if it has started; drop it if it has not. Quit does not wait for it.
    case continueOnShutdown
    /// Drop it if it has not started (a ``BackgroundWork/run(_:mayBlock:shutdown:_:)`` caller gets
    /// `CancellationError`); quit does not wait for a started one. The default: reads and anything a
    /// later launch redoes.
    case skipOnShutdown
    /// Quit waits for it: a save whose loss loses a person's data. Keep these short.
    case blockShutdown
}
