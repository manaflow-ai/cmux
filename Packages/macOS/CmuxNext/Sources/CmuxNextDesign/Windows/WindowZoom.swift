public import AppKit

/// The Zoom toggle of a shell window (Window > Zoom, the green button, a titlebar double-click,
/// Ghostty's `toggle_maximize`, `cmux app zoom-window`) without AppKit's blocking animation.
///
/// `NSWindow.zoom(_:)` resizes with `setFrame(_:display:animate: true)`, which runs the whole
/// resize animation in a nested loop before it returns: the key's turn held the main thread about
/// 380 ms (every-action sweep, zoomWindow, macOS 27, light and STRESS), laying out the window at
/// every step, and no key or click was dispatched meanwhile. Here the zoom starts an animation on
/// the run loop (the window animator) and returns at once; the person's input keeps being
/// dispatched between its frames.
///
/// The toggle follows AppKit's: a window away from its standard frame zooms to it and remembers
/// where it was; a window at its standard frame goes back to the remembered frame. While a zoom
/// animates, its target is the window's frame for that decision (a second press reverses it) and
/// for ``isZoomed``. The resize goes through the panes Motion gate: with Reduce Motion or animations
/// off it happens at once.
///
/// A window keeps one value and forwards to it:
///
/// ```swift
/// private var zoomState = WindowZoom()
/// override func zoom(_ sender: Any?) { if !zoomState.zoom(self) { super.zoom(sender) } }
/// override var isZoomed: Bool { zoomState.isZoomingIn ?? super.isZoomed }
/// ```
@MainActor
public struct WindowZoom {
    /// The frame before the last zoom to the standard frame; nil when there is none to go back to.
    private(set) var userFrame: NSRect?
    /// The frame the running animation moves to; nil when no zoom animates.
    private(set) var animatingTo: NSRect?
    /// The standard frame the running animation's decision used.
    private var animatingStandard: NSRect?
    /// Distinguishes animations, so a finished one does not clear a newer one.
    private var generation = 0

    /// Points two frames may differ by and still count as the same (AppKit's own zoom rounds).
    static let tolerance: CGFloat = 1

    public init() {}

    /// Zooms `window` (AppKit's toggle, ``WindowZoom``) and returns true; false for a full-screen or
    /// screenless window, which the caller hands to `super.zoom(_:)`.
    public mutating func zoom(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return false }
        let standard = window.delegate?.windowWillUseStandardFrame?(window, defaultFrame: screen.visibleFrame) ?? screen.visibleFrame
        guard let target = target(from: window.frame, standard: standard) else { return true }
        let generation = begin(to: target, standard: standard)
        let box = WindowZoomCompletion(window: window)
        Motion.panes.animateTimed(.move, in: window.contentView, { window.animator().setFrame(target, display: true) },
                                  completion: { box.window?.windowZoomFinished(generation) })
        return true
    }

    /// Where a zoom moves a window now at `frame` (its running animation's target while one runs),
    /// given its standard frame; nil when it is at the standard frame with nothing to go back to.
    mutating func target(from frame: NSRect, standard: NSRect) -> NSRect? {
        let current = animatingTo ?? frame
        if Self.same(current, standard) {
            guard let back = userFrame else { return nil }
            userFrame = nil
            return back
        }
        userFrame = current
        return standard
    }

    /// Records the animation that moves the window to `target` and returns its generation.
    mutating func begin(to target: NSRect, standard: NSRect) -> Int {
        generation &+= 1
        animatingTo = target
        animatingStandard = standard
        return generation
    }

    /// The animation of `finished` ended (a newer one may run).
    public mutating func end(_ finished: Int) {
        guard finished == generation else { return }
        animatingTo = nil
        animatingStandard = nil
    }

    /// Whether the running animation ends at its standard frame; nil when none runs.
    public var isZoomingIn: Bool? {
        guard let target = animatingTo, let standard = animatingStandard else { return nil }
        return Self.same(target, standard)
    }

    static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
