import AppKit
import CmuxNextActions
import CmuxNextDesign

/// A window the person closes (the close button, Close Window, Cmd-Shift-W) fades out as a whole
/// before it closes (plans/cmux-next/close-animation/DESIGN.md).
///
/// The fade runs on the render server: one additive `exit`
/// spring (critically damped, so the window never comes back up) takes the frame view's layer
/// opacity to 0. Nothing runs on the main thread per frame and the window server gets no call per
/// frame. This is Chromium's window hide animation (ui/wm/core/window_animations.cc
/// `AnimateHideWindowCommon`: the window's layer opacity animates on the compositor, and the
/// window goes away when the animation ends).
///
/// The layer fades as one group (`allowsGroupOpacity`), so overlapping sublayers never show
/// through each other: Chromium's compositor does the same, a render surface for a translucent
/// subtree with more than one drawing layer (cc/trees/property_tree_builder.cc). The window's
/// look changes twice, not per frame: in the key's turn it turns non-opaque, so the faded layer
/// shows what is behind it, and drops its shadow; on the close it gets both back.
///
/// The shadow does not fade. The window server draws it outside the window from a mask it reads
/// only on `invalidateShadow`, so it cannot follow a render-server opacity without a window call
/// per frame, which is what this fade removes. It leaves in the key's frame instead: the person
/// sees the shadow go as the fade starts, then the content fade (the old window-alpha fade took
/// the shadow down with it).
///
/// The keys go to the next window at once and the fading window takes no click, so nothing
/// reaches a window that is leaving. Its state closes when the fade lands, or when another spring
/// takes over its layer's opacity: a close that started always ends in a close. Nothing moves into
/// another window during a user close, so the fading window never fights one for its surfaces. A
/// second close while it fades closes it at once. A window the registry closes (its workspace
/// moved or ended, `WindowManager.closeProgrammatically`) never fades, and Reduce Motion, the
/// animation speed "off", a window with no screen or a sleeping display closes at once.
///
/// The window's child windows leave in the key's frame too. AppKit does not apply a parent's
/// `alphaValue`, nor its frame view's layer opacity, to its children, and a Chromium page, a remote
/// browser popup and the overlay and mouse-catcher panels above them are child windows: left alone
/// they stayed opaque on an empty frame for the whole fade and went only at its end (#25197). Like
/// the shadow they cannot follow a render-server opacity without a window call per frame, so the
/// whole child tree goes to alpha 0 as the fade starts and gets its own alpha back on the close.
@MainActor final class WindowCloseMotion {
    /// Runs the fade of `layer`, shown in `view`, to opacity 0, and calls `landed` once when it
    /// ends (finished, or taken over by a newer spring).
    typealias Fade = @MainActor (_ layer: CALayer, _ view: NSView, _ landed: @escaping RenderSpring.Completion) -> Void

    /// The look the fade changed, put back on the close (a closed window may show again).
    private struct Look {
        let layer: CALayer
        let allowsGroupOpacity: Bool
        let isOpaque: Bool
        let hasShadow: Bool
    }

    let window: NSWindow
    private let fade: Fade
    private let close: () -> Void
    private var finished = false
    private var look: Look?
    /// Each child window the fade hid, with the alpha it had: it gets that back on the close.
    private var children: [(window: NSWindow, alpha: CGFloat)] = []

    /// The opacity key path the fade springs.
    static let key = RenderSpringKey<CGFloat>.opacity

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

    /// The fade on `gate`'s `token` spring: the layer's opacity springs to 0 on the render server.
    static func springFade(_ token: MotionSpring, on gate: MotionGate) -> Fade {
        { layer, view, landed in
            gate.renderSpring(token).animate(layer, WindowCloseMotion.key, to: CGFloat(0), in: view, completion: landed)
        }
    }

    /// - Parameters:
    ///   - window: The window that closes.
    ///   - fade: Runs the fade (the `exit` spring on the panes gate); tests land it themselves.
    ///   - close: Closes the window for real, once, when the fade lands.
    init(window: NSWindow, fade: @escaping Fade = WindowCloseMotion.springFade(.exit, on: Motion.panes),
         close: @escaping () -> Void) {
        self.window = window
        self.fade = fade
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
        look = Look(layer: layer, allowsGroupOpacity: layer.allowsGroupOpacity, isOpaque: window.isOpaque,
                    hasShadow: window.hasShadow)
        layer.allowsGroupOpacity = true
        window.isOpaque = false
        window.hasShadow = false
        hideChildWindows()
        fade(layer, view) { [weak self] _ in self?.finish() }
    }

    /// Closes the window now (the fade landed or was taken over, or a second close came), once.
    func finish() {
        guard !finished else { return }
        finished = true
        close()
        // A closed window may show again (reopen): it shows whole, with its own look. The layer is
        // the one the fade started on, whatever the close did to the frame view.
        if let look {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            RenderSpring.stop(look.layer, Self.key.path)
            look.layer.opacity = 1
            look.layer.allowsGroupOpacity = look.allowsGroupOpacity
            CATransaction.commit()
            window.isOpaque = look.isOpaque
            window.hasShadow = look.hasShadow
            self.look = nil
        }
        window.ignoresMouseEvents = false
        restoreChildWindows()
    }

    /// Hides every window below the window in its child tree (one call each, in the key's frame).
    private func hideChildWindows() {
        var pending = window.childWindows ?? []
        while let child = pending.popLast() {
            pending += child.childWindows ?? []
            children.append((child, child.alphaValue))
            child.alphaValue = 0
        }
    }

    /// Gives each hidden child its alpha back, unless its owner set another during the fade, or it
    /// left every window and still shows (a page its host let go of on close): that one stays hidden.
    private func restoreChildWindows() {
        for child in children where child.window.alphaValue == 0
            && (child.window.parent != nil || !child.window.isVisible) {
            child.window.alphaValue = child.alpha
        }
        children = []
    }
}
