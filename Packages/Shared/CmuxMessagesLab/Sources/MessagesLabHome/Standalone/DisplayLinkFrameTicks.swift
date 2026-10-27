import AppKit

/// Frames from a display link of the view's own (MessagesLab bd65bbf FrameTick's link), for hosts
/// with no frame scheduler of their own: tests and standalone MessagesLab. CmuxNext never uses it:
/// its Home passes a FrameScheduler client (CmuxNextHome HomeFrameTicks).
@MainActor
public final class DisplayLinkFrameTicks: FrameTickSource {
    /// Nonisolated: it is the default argument of MessagesLabHomeView's and ChatController's inits,
    /// and a Swift 5 module evaluates default arguments outside the main actor. It holds no state.
    nonisolated public init() {}

    public func frames(for view: NSView, onFrame: @escaping @MainActor @Sendable () -> Bool) -> any FrameTickStream {
        DisplayLinkFrameTickStream(view: view, onFrame: onFrame)
    }
}

/// A paused link on the main run loop's common modes (so it also fires in a divider drag's or live
/// resize's tracking loop); the frame that finds no work pauses it again.
@MainActor
private final class DisplayLinkFrameTickStream: NSObject, FrameTickStream {
    private let onFrame: @MainActor @Sendable () -> Bool
    private var link: CADisplayLink?

    init(view: NSView, onFrame: @escaping @MainActor @Sendable () -> Bool) {
        self.onFrame = onFrame
        super.init()
        // wakeup-allow: fixture standalone MessagesLab and tests only; CmuxNext Home injects its FrameScheduler
        let link = view.displayLink(target: self, selector: #selector(fire(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func start() { link?.isPaused = false }

    /// The view's link follows the view to its new window's screen by itself.
    func restart() { start() }

    @objc private func fire(_ link: CADisplayLink) {
        link.isPaused = !onFrame()
    }
}
