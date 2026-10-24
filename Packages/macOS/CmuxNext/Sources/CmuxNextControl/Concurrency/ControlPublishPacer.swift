import CmuxNextWakeups

/// When the control snapshot publishes: on the next display frame, or, for a model change soon
/// after the last publish, on the first frame after a delay.
///
/// A delay is one one-shot `DemandTimer` deadline; nothing ticks while it runs. (Before, the
/// App's publisher asked for a display frame on every frame until the delay passed: about 12
/// main-thread wakeups at 120 Hz per model change.) A reader that starts waiting for a newer
/// snapshot (``follow(waiters:)``) ends a pending delay at once.
///
/// ```swift
/// let pacer = ControlPublishPacer(frames: frames)
/// pacer.publish = { [weak self] in self?.publishNow() }
/// pacer.follow(waiters: router.snapshots.waiterAdditions())
/// pacer.request(after: lastPublish + .milliseconds(100) - .now)
/// ```
///
/// Tests pass a frame source they run by hand and a manual `Clock`.
@MainActor
public final class ControlPublishPacer {
    private let frames: any ControlFrameSource
    private let deadline: DemandTimer
    /// A frame is asked for and has not published yet.
    private var frameRequested = false
    private var isStopped = false
    /// Iterates ``ControlSnapshotStore/waiterAdditions()`` (``follow(waiters:)``).
    private var waiterTask: Task<Void, Never>?
    /// Runs one publish; the owner sets it once, before the first request.
    public var publish: @MainActor () -> Void = {}

    /// Makes a pacer that publishes nothing until a request.
    ///
    /// - Parameters:
    ///   - frames: Where the publish frame comes from (the App's frame batcher).
    ///   - clock: Times a delay; the default is the continuous clock, tests pass a manual one.
    public init(frames: any ControlFrameSource, clock: any Clock<Duration> = ContinuousClock()) {
        self.frames = frames
        deadline = DemandTimer(owner: "ControlSnapshotPublisher.modelChange", clock: clock)
    }

    /// Publishes on the next frame; a pending delay gives way.
    public func requestFrame() {
        guard !isStopped else { return }
        deadline.cancel()
        guard !frameRequested else { return }
        frameRequested = true
        frames.scheduleFrame { [weak self] in
            guard let self, self.frameRequested else { return }
            self.frameRequested = false
            self.publish()
        }
    }

    /// Publishes on the first frame `delay` from now. A pending frame or delay stays as it is:
    /// every delay between two publishes ends at the same time (the last publish plus the interval).
    ///
    /// - Parameter delay: How long to wait before asking for the frame; zero or less asks now.
    public func request(after delay: Duration) {
        guard !isStopped else { return }
        guard delay > .zero else { return requestFrame() }
        guard !frameRequested, !deadline.isScheduled else { return }
        deadline.schedule(after: delay) { @MainActor [weak self] in self?.requestFrame() }
    }

    /// A reader started waiting for a newer snapshot: a publish held for a delay goes now.
    public func readerWaits() {
        guard !isStopped, deadline.isScheduled else { return }
        cancel()
        publish()
    }

    /// Calls ``readerWaits()`` for each element of `waiters` until ``stop()``.
    ///
    /// - Parameter waiters: A store's ``ControlSnapshotStore/waiterAdditions()``.
    public func follow(waiters: AsyncStream<Void>) {
        waiterTask?.cancel()
        // task-owner: the waiter stream's reader; cancelled by stop()
        waiterTask = Task { @MainActor [weak self] in
            for await _ in waiters {
                guard let self else { return }
                self.readerWaits()
            }
        }
    }

    /// Drops a pending publish (one just ran).
    public func cancel() {
        deadline.cancel()
        frameRequested = false
    }

    /// Publishes nothing more.
    public func stop() {
        isStopped = true
        waiterTask?.cancel()
        waiterTask = nil
        cancel()
    }
}
