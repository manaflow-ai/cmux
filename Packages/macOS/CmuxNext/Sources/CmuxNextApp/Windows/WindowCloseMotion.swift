import AppKit
import CmuxNextActions
import CmuxNextDesign

/// A window the person closes (the close button, Close Window, Cmd-Shift-W) fades out as a whole
/// before it closes (plans/cmux-next/close-animation/DESIGN.md).
///
/// The fade runs on the render server (chrome-parity task p03-rendering-034): the window turns
/// non-opaque with no shadow, and one additive `exit` spring (critically damped, so the window
/// never comes back up) takes its frame view's layer opacity to 0. Nothing runs on the main
/// thread per frame and the window server gets no call during the fade. This is Chromium's window
/// hide animation (ui/wm/core/window_animations.cc `AnimateHideWindowCommon`: the window's layer
/// opacity animates on the compositor, and the window goes away when the animation ends).
///
/// The keys go to the next window at once and the fading window takes no click, so nothing
/// reaches a window that is leaving. Its state closes when the fade lands: nothing moves into
/// another window during a user close, so the fading window never fights one for its surfaces. A
/// second close while it fades closes it at once. A window the registry closes (its workspace
/// moved or ended, `WindowManager.closeProgrammatically`) never fades, and Reduce Motion, the
/// animation speed "off", a window with no screen or a sleeping display closes at once.
@MainActor final class WindowCloseMotion {
    let window: NSWindow
    private let spring: RenderSpring
    private let close: () -> Void
    private var finished = false
    /// The window's look before the fade, put back when it closes (a closed window may show again).
    private var restore: (isOpaque: Bool, hasShadow: Bool)?

    /// The opacity key path the fade springs.
    static let keyPath = "opacity"

    /// Whether a close from `origin` is the person's (a click, a key, a page control they drew):
    /// only that close fades. A script, the CLI, MCP or another client closes at once, so the
    /// window has left when its `action.run` answers.
    nonisolated static func isPersonsClose(_ origin: ActionOrigin) -> Bool {
        origin == .user || origin == .page
    }

    /// Whether a close of `window` fades: it shows on screen, motion is on, and its frame view
    /// has a layer to fade.
    static func fades(_ window: NSWindow, animates: Bool = Motion.panes.animatesMovement) -> Bool {
        animates && window.isVisible && !window.isMiniaturized && !window.styleMask.contains(.fullScreen)
            && fadingLayer(of: window) != nil
    }

    /// The layer whose opacity fades: the frame view's, which holds the content and the titlebar.
    static func fadingLayer(of window: NSWindow) -> CALayer? {
        frameView(of: window)?.layer
    }

    private static func frameView(of window: NSWindow) -> NSView? {
        window.contentView?.superview
    }

    /// - Parameters:
    ///   - window: The window that closes.
    ///   - spring: The fade's spring (`exit` on the panes gate).
    ///   - close: Closes the window for real, once, when the fade lands.
    init(window: NSWindow, spring: RenderSpring = Motion.panes.renderSpring(.exit), close: @escaping () -> Void) {
        self.window = window
        self.spring = spring
        self.close = close
    }

    /// Starts the fade: the window takes no more clicks, `next` takes the keys now. With no layer
    /// to fade, or when the gate does not animate it, the window closes now.
    ///
    /// - Parameter next: The window that takes the keys (the next one front to back), if any.
    func start(handingKeysTo next: NSWindow?) {
        window.ignoresMouseEvents = true
        if window.isKeyWindow, let next { next.makeKey() }
        guard let view = Self.frameView(of: window), let layer = view.layer else {
            finish()
            return
        }
        restore = (window.isOpaque, window.hasShadow)
        window.isOpaque = false
        window.hasShadow = false
        spring.animate(layer, Self.keyPath, to: CGFloat(0), in: view) { [weak self] finished in
            if finished { self?.finish() }
        }
    }

    /// Closes the window now (the fade landed, or a second close came), once.
    func finish() {
        guard !finished else { return }
        finished = true
        close()
        // A closed window may show again (reopen): it shows whole, with its own look.
        if let layer = Self.fadingLayer(of: window) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            RenderSpring.stop(layer, Self.keyPath)
            layer.opacity = 1
            CATransaction.commit()
        }
        if let restore {
            window.isOpaque = restore.isOpaque
            window.hasShadow = restore.hasShadow
        }
        window.ignoresMouseEvents = false
    }
}
