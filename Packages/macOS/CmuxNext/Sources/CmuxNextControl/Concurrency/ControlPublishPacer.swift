import Foundation

/// When the control snapshot publishes: on the next display frame, or, for a model change soon
/// after the last publish, on the first frame after a delay.
///
/// This is the App publisher's pacing moved here unchanged, so it can be tested with a frame
/// source run by hand and a manual clock: a delay asks for a display frame on every frame until
/// it passes.
@MainActor
public final class ControlPublishPacer {
    private let frames: any ControlFrameSource
    private var isScheduled = false
    /// A delayed publish waits until then; nil publishes on the next frame.
    private var notBefore: ContinuousClock.Instant?
    private var isStopped = false
    /// Runs one publish; the owner sets it once, before the first request.
    public var publish: @MainActor () -> Void = {}
    /// Whether a frame publishes now even before its delay (a reader waits on the snapshot).
    public var isUrgent: @MainActor () -> Bool = { false }

    /// Makes a pacer that publishes nothing until a request.
    ///
    /// - Parameters:
    ///   - frames: Where the publish frame comes from (the App's frame batcher).
    ///   - clock: Not read yet: the delay is checked against the continuous clock on each frame.
    public init(frames: any ControlFrameSource, clock: any Clock<Duration> = ContinuousClock()) {
        self.frames = frames
    }

    /// Publishes on the next frame.
    public func requestFrame() {
        schedule(notBefore: nil)
    }

    /// Publishes on the first frame `delay` from now (a pending request keeps the earlier time).
    ///
    /// - Parameter delay: How long to wait before publishing.
    public func request(after delay: Duration) {
        schedule(notBefore: .now + delay)
    }

    /// Whether a delayed publish is waiting.
    public var isWaiting: Bool { isScheduled && notBefore != nil }

    /// Drops a pending publish (one just ran).
    public func cancel() {
        notBefore = nil
    }

    /// Publishes nothing more.
    public func stop() {
        isStopped = true
        cancel()
    }

    private func schedule(notBefore: ContinuousClock.Instant?) {
        self.notBefore = notBefore.flatMap { new in isScheduled ? self.notBefore.map { min($0, new) } : new }
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            if let wait = self.notBefore, ContinuousClock.now < wait, !self.isUrgent() { return self.schedule(notBefore: wait) }
            self.notBefore = nil
            self.publish()
        }
    }
}
