public import AppKit

/// A child window of a main window that is page content, like a Chromium
/// page window, for content that must reach past the window's edge (a
/// remote browser tab's date picker or suggestion list near the page edge).
/// The overlay host treats it as a page window (`isPageWindow`): it stays
/// below the host panel and every app overlay (palette, dialogs, toasts),
/// a click the host passes on can reach it, and `ChildWindowPolicy` allows
/// it. AppKit moves a child window with its parent (drags, Spaces).
///
/// Borderless, transparent and non-activating; it never becomes key or
/// main, so keys stay with the window's first responder. It is shown only
/// by adding it as a child of a visible window (`addChildWindow`), never by
/// itself, so it never takes the display.
open class ContentChildPanel: NSPanel {
    public init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override open var canBecomeKey: Bool { false }
    override open var canBecomeMain: Bool { false }
}
