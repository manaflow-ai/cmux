public import AppKit

/// A floating overlay's own child panel above a Chromium page window.
///
/// Borderless, transparent, non-activating: it never becomes key or main, so
/// the keyboard stays with the window's first responder, and it is shown only
/// as a child of a visible window, so it never takes the display. Sized to
/// its overlay, so the rest of the page keeps the mouse.
///
/// The fork re-adds a page window above every other child each time it shows
/// or moves, so `place(over:in:)` re-adds this panel when a page window sits
/// above it (`order(_:relativeTo:)` has no effect on child windows).
///
/// Reference: cmux Next `CmuxNextDesign/Overlay/OverlayHostPanel.swift`,
/// `WindowOverlayHost.reassertOrder()`, `ContentChildPanel.swift`.
final class BrowserPageFloatingOverlayPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        content.autoresizingMask = [.width, .height]
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel at `screenRect` as a child of `window`, above every
    /// page window of it.
    func place(over screenRect: CGRect, in window: NSWindow) {
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        } else if hasPageWindowAbove(in: window) {
            window.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        if frame != screenRect { setFrame(screenRect, display: true) }
        if !isVisible { orderFront(nil) }
        if appearance !== window.effectiveAppearance { appearance = window.effectiveAppearance }
    }

    /// Takes the panel off screen.
    func detach() {
        parent?.removeChildWindow(self)
        if isVisible { orderOut(nil) }
    }

    private func hasPageWindowAbove(in window: NSWindow) -> Bool {
        let children = window.childWindows ?? []
        guard let index = children.firstIndex(where: { $0 === self }) else { return true }
        return children[(index + 1)...].contains { $0.isVisible && $0.isChromiumPageWindow }
    }
}
