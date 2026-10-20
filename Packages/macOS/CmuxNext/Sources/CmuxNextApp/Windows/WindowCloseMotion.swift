import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A window the person closes (the close button, Close Window, Cmd-Shift-W) fades out as a whole
/// before it closes (plans/cmux-next/close-animation/DESIGN.md).
///
/// The fade starts in the key's frame and runs on the `exit` spring (critically damped, so the
/// window never comes back up). The keys go to the next window at once and the fading window takes
/// no click, so nothing reaches a window that is leaving. Its state closes when the fade ends:
/// nothing moves into another window during a user close, so the fading window never fights one
/// for its surfaces. A second close while it fades closes it at once. A window the registry closes
/// (its workspace moved or ended, `WindowManager.closeProgrammatically`) never fades, and Reduce
/// Motion or the animation speed "off" closes at once.
@MainActor final class WindowCloseMotion {
    let window: NSWindow
    private var alpha = SpringValue(1)
    private let parameters: SpringParameters
    private let close: () -> Void
    private var finished = false
    private lazy var frames = FrameClient(owner: "WindowCloseMotion.fade", on: .app) { [weak self] tick in
        self?.step(tick.elapsed) ?? false
    }

    /// Whether a close of `window` fades: it shows on screen and motion is on.
    static func fades(_ window: NSWindow, animates: Bool = Motion.animatesMovement) -> Bool {
        animates && window.isVisible && !window.isMiniaturized && !window.styleMask.contains(.fullScreen)
    }

    /// - Parameters:
    ///   - window: The window that closes.
    ///   - parameters: The fade's spring (`exit` at the animation speed).
    ///   - close: Closes the window for real, once, when the fade ends.
    init(window: NSWindow, parameters: SpringParameters = Motion.spring(.exit), close: @escaping () -> Void) {
        self.window = window
        self.parameters = parameters
        self.close = close
    }

    /// Starts the fade: the window takes no more clicks, `next` takes the keys now.
    ///
    /// - Parameters:
    ///   - next: The window that takes the keys (the next one front to back), if any.
    ///   - driven: Whether display frames drive the fade; tests step it with ``step(_:)``.
    func start(handingKeysTo next: NSWindow?, driven: Bool = true) {
        window.ignoresMouseEvents = true
        if window.isKeyWindow, let next { next.makeKey() }
        alpha.target = 0
        if driven { frames.activate() }
    }

    /// One frame of the fade; false once the window closed.
    @discardableResult
    func step(_ dt: Double) -> Bool {
        guard !finished else { return false }
        let moving = alpha.advance(dt, parameters: parameters, epsilon: 0.01)
        window.alphaValue = max(0, alpha.value)
        if !moving { finish() }
        return moving
    }

    /// Closes the window now (the fade ended, or a second close came), once.
    func finish() {
        guard !finished else { return }
        finished = true
        frames.deactivate()
        close()
        // A closed window may show again (reopen): it shows whole.
        window.alphaValue = 1
        window.ignoresMouseEvents = false
    }
}
