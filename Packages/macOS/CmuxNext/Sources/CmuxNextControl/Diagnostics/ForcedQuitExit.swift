import Darwin

/// The exit of a second quit signal while a quit runs (`QuitSignal`): the stuck quit is not waited for.
///
/// The first ``start()`` runs `prepare` (the crash marker and hang report ends, Home's links), arms the
/// deadline, then runs `save` (the Home cache's last batch: drafts) and ends the process. A later call does
/// nothing, so a third signal never starts a second end. The deadline is a dedicated thread's `_exit`
/// (``QuitDeadline``): neither a full cooperative pool nor a blocked main thread (the stuck quit this exit is
/// for) can hold the process, and no atexit handler runs beside AppKit and Chromium. The normal end is
/// `exit(0)` on the main actor after the save, as AppKit's own.
///
/// The limit is 160 ms: 3x the measured p99 of a first Home cache write after launch with a large Home
/// (52 ms, HomeCacheQuitWriteTimeTests). Tests inject the deadline and the end.
@MainActor
public final class ForcedQuitExit {
    private let limit: Duration
    private let prepare: @MainActor () -> Void
    private let save: @MainActor () async -> Void
    private let armDeadline: (Duration) -> Void
    private let end: @MainActor () -> Void
    private var started = false

    /// - Parameters:
    ///   - limit: How long `save` may take before the deadline ends the process.
    ///   - prepare: The synchronous last steps, before the deadline is armed.
    ///   - save: The bounded last write.
    ///   - armDeadline: Arms the hard end after `limit` (default: a ``QuitDeadline``, `_exit` on its own thread).
    ///   - deadlineEnd: The default deadline's end (it records what `save` had not written, then ends).
    ///   - end: Ends the process after `save` (default: `exit(0)`).
    public init(limit: Duration = .milliseconds(160),
         prepare: @escaping @MainActor () -> Void,
         save: @escaping @MainActor () async -> Void,
         armDeadline: ((Duration) -> Void)? = nil,
         deadlineEnd: (@Sendable () -> Void)? = nil,
         end: (@MainActor () -> Void)? = nil) {
        self.limit = limit
        self.prepare = prepare
        self.save = save
        self.armDeadline = armDeadline ?? {
            QuitDeadline(reason: "a forced quit began its last writes (the Home cache, the agent panes' state files)", end: deadlineEnd).arm(after: $0)
        }
        self.end = end ?? { exit(0) }
    }

    /// Starts the exit once.
    ///
    /// - Returns: The task that saves and then ends the process; nil when an exit already started.
    @discardableResult
    public func start() -> Task<Void, Never>? {
        guard !started else { return nil }
        started = true
        prepare()
        armDeadline(limit)
        let save = save, end = end
        // task-owner: the forced quit's last save; the process ends after it or at the deadline
        return Task { @MainActor in
            await save()
            end()
        }
    }
}
