public import AppKit
import QuartzCore

/// One frame delivered to a ``FrameClient``.
public struct FrameTick: Sendable {
    /// Display-link time of this frame (CACurrentMediaTime base).
    public var timestamp: CFTimeInterval
    /// Seconds since the previous frame, clamped to 1/240...1/30.
    public var elapsed: Double
}

/// A reason to receive frames: an animation, a drag autoscroll, a settle
/// wait. Active clients keep their scheduler's display link running; the
/// tick returns false to go idle, and the link stops with the last client.
@MainActor
public final class FrameClient {
    public let owner: String
    private let onFrame: @MainActor (FrameTick) -> Bool
    private let resolve: @MainActor () -> FrameScheduler
    private weak var scheduler: FrameScheduler?
    public private(set) var isActive = false

    /// `onFrame` returns true to keep ticking. The client ticks on the
    /// scheduler `resolve` returns when it activates.
    public init(owner: String, scheduler resolve: @escaping @MainActor () -> FrameScheduler,
                onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.owner = owner
        self.resolve = resolve
        self.onFrame = onFrame
    }

    /// A client of `view`'s window (``FrameScheduler/app`` while it has none).
    public convenience init(owner: String, view: NSView, onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app }, onFrame: onFrame)
    }

    /// A client of a fixed scheduler.
    public convenience init(owner: String, on scheduler: FrameScheduler, onFrame: @escaping @MainActor (FrameTick) -> Bool) {
        self.init(owner: owner, scheduler: { [unowned scheduler] in scheduler }, onFrame: onFrame)
    }

    /// Starts ticking (no effect while active).
    public func activate() {
        guard !isActive else { return }
        isActive = true
        let target = resolve()
        scheduler = target
        target.activate(self)
    }

    /// Stops ticking.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        scheduler?.deactivate(self)
        scheduler = nil
    }

    /// The scheduler went away: idle without calling back.
    func detach() {
        isActive = false
        scheduler = nil
    }

    /// Delivers a frame; false when the client went idle.
    func fire(_ tick: FrameTick) -> Bool {
        guard isActive else { return false }
        if onFrame(tick) && isActive { return true }
        isActive = false
        scheduler = nil
        return false
    }

    isolated deinit {
        deactivate()
    }
}
