import CmuxNextControl
import Foundation

/// When the control snapshot publishes (``ControlSnapshotPublisher``): on the next display frame,
/// or, for a model change soon after the last publish, on the first frame after a delay.
@MainActor
final class ControlPublishPacer {
    private let frames: any ControlFrameSource
    private var isScheduled = false
    /// A delayed publish waits until then; nil publishes on the next frame.
    private var notBefore: ContinuousClock.Instant?
    private var isStopped = false
    /// Runs one publish.
    var publish: @MainActor () -> Void = {}
    /// Whether a frame publishes now even before its delay (a reader waits on the snapshot).
    var isUrgent: @MainActor () -> Bool = { false }

    init(frames: any ControlFrameSource, clock: any Clock<Duration> = ContinuousClock()) {
        self.frames = frames
    }

    /// Publishes on the next frame.
    func requestFrame() {
        schedule(notBefore: nil)
    }

    /// Publishes on the first frame `delay` from now (a pending request keeps the earlier time).
    func request(after delay: Duration) {
        schedule(notBefore: .now + delay)
    }

    /// Whether a delayed publish is waiting.
    var isWaiting: Bool { isScheduled && notBefore != nil }

    /// Drops a pending publish (one just ran).
    func cancel() {
        notBefore = nil
    }

    /// Publishes nothing more.
    func stop() {
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
