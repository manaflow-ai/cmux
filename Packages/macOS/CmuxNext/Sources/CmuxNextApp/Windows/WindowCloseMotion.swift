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
///
/// The fade covers the window's child windows too. AppKit does not apply a parent's `alphaValue`
/// to its children, and a Chromium page, a remote browser popup and the overlay and mouse-catcher
/// panels above them are child windows: faded on the parent alone, the pages stayed opaque on an
/// empty frame for the whole fade and went only at its end.
@MainActor final class WindowCloseMotion {
    let window: NSWindow
    private var alpha = SpringValue(1)
    private let parameters: SpringParameters
    private let close: () -> Void
    private var finished = false
    /// Each child window the fade has dimmed, with the alpha it had and the last alpha the fade
    /// set: it fades from the first and gets it back when the fade ends. A child added during the
    /// fade (the fork re-adds a page window that becomes visible) joins in the next frame.
    private var children: [ObjectIdentifier: (window: NSWindow, alpha: CGFloat, set: CGFloat)] = [:]
    /// Children whose owner set their alpha during the fade: the fade leaves them alone after.
    private var released: Set<ObjectIdentifier> = []
    private lazy var frames = FrameClient(owner: "WindowCloseMotion.fade", on: .app) { [weak self] tick in
        self?.step(tick.elapsed) ?? false
    }

    /// Whether a close of `window` fades: it shows on screen and motion is on.
    static func fades(_ window: NSWindow, animates: Bool = Motion.panes.animatesMovement) -> Bool {
        animates && window.isVisible && !window.isMiniaturized && !window.styleMask.contains(.fullScreen)
    }

    /// - Parameters:
    ///   - window: The window that closes.
    ///   - parameters: The fade's spring (`exit` at the animation speed).
    ///   - close: Closes the window for real, once, when the fade ends.
    init(window: NSWindow, parameters: SpringParameters = Motion.panes.spring(.exit), close: @escaping () -> Void) {
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
        apply(max(0, alpha.value))
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
        // A child gets its alpha back unless its owner set another during the fade, or it left
        // the window and still shows (a page its host let go of on close): that one stays faded.
        for child in children.values where child.window.alphaValue == child.set
            && (child.window.parent === window || !child.window.isVisible) {
            child.window.alphaValue = child.alpha
        }
        children = [:]
        released = []
    }

    /// Sets the fade's alpha on the window and on every window below it in the child tree.
    private func apply(_ value: CGFloat) {
        window.alphaValue = value
        for (id, child) in children {
            if child.window.alphaValue != child.set {
                // Its owner set another alpha (a panel's own fade): that one is the owner's now.
                children[id] = nil
                released.insert(id)
            } else if let parent = child.window.parent, !contains(parent) {
                // It moved under another window (a palette follows the key window): whole again.
                child.window.alphaValue = child.alpha
                children[id] = nil
            }
        }
        var pending = window.childWindows ?? []
        while let child = pending.popLast() {
            pending += child.childWindows ?? []
            let id = ObjectIdentifier(child)
            guard !released.contains(id) else { continue }
            let base = children[id]?.alpha ?? child.alphaValue
            child.alphaValue = base * value
            children[id] = (child, base, child.alphaValue)
        }
    }

    /// Whether `other` is the window or below it in its child tree.
    private func contains(_ other: NSWindow) -> Bool {
        var next: NSWindow? = other
        while let candidate = next {
            if candidate === window { return true }
            next = candidate.parent
        }
        return false
    }
}
