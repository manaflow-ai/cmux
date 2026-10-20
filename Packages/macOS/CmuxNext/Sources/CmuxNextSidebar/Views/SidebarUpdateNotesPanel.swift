import AppKit
import CmuxNextDesign

/// The update card's highlights popup (Leo 2026-10-13): the popup every cmux popover is, not
/// AppKit's NSPopover with its stock arrow. A borderless child window of the sidebar's window
/// holding the popup surface (themed glass, or the solid card under Reduce Transparency) with its hairline and shadow (`Glass.makeOverlayPanel`,
/// `PopupStyle`), beside the card toward the content (left of it for a sidebar on the right, or
/// with no room on the right) and top-aligned with it, in the card's theme. It takes clicks
/// ("See all changes") and never becomes key, so the keys stay with the window. The app going
/// inactive closes it (a no-activate run is never active, so there it stays).
@MainActor
final class SidebarUpdateNotesPanel: NSPanel {
    /// The highlights page's host: the pointer leaving it closes the popup.
    let host: SidebarPopoverIslandHost
    let glass: OverlaySurfaceView
    /// The close finished: the highlights page can go back to wait in the card.
    var onClosed: (() -> Void)?
    /// A close starts (any cause: the card, an action, the app resigning active), before its animation.
    var onDismiss: (() -> Void)?
    /// Shown (or opening) and not yet dismissed.
    private(set) var isPresented = false
    private let width: CGFloat
    /// The card it opened from (screen), where it grows from and closes to.
    private var anchor: CGRect = .zero
    private var height: CGFloat = 1
    /// Bumped by every open and close, so a close that a reopen overtook keeps the panel.
    private var generation = 0
    private weak var adoptedScope: ThemeScope?
    private var resignObserver: (any NSObjectProtocol)?

    init(width: CGFloat) {
        self.width = width
        host = SidebarPopoverIslandHost(width: width)
        glass = Glass.makeOverlayPanel(content: host, cornerRadius: PopupStyle.standard.cornerRadius)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        adoptPopupStyle(card: glass)
        isReleasedWhenClosed = false
        // Closed on deactivation instead (below): a hidden panel AppKit shows again on
        // reactivation would stay open with no pointer exit to close it.
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !WindowPlacement.noActivate { self?.dismiss() } } // main-proof: observer on queue: .main
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card's frame on screen (the window less its shadow band).
    var cardFrame: CGRect { PopupStyle.standard.cardFrame(inWindow: frame) }

    /// Shows the popup beside `anchor` (the card, screen coordinates) as a child of `parent`,
    /// `height` tall, drawn in `themeAnchor`'s theme.
    func present(beside anchor: CGRect, height: CGFloat, parent: NSWindow, themeAnchor: NSView) {
        let reopening = !isPresented && isVisible
        isPresented = true
        ignoresMouseEvents = false
        generation += 1
        self.anchor = anchor
        self.height = height
        let scope = themeAnchor.themeScope.fullStrength
        if adoptedScope !== scope {
            scope.adopt(self)
            scope.addResponder(self)
            adoptedScope = scope
        }
        themeDidChange()
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        place()
        // Already showing or fading in: it stays as it is (a second hover never restarts the fade).
        guard !isVisible || reopening else { return }
        if !reopening { alphaValue = 0 }
        orderFront(nil)
        openPopup(pivot: popupPivot(toward: anchor))
    }

    /// The page's height changed while it shows.
    func resize(height: CGFloat) {
        guard isPresented, height != self.height else { return }
        self.height = height
        place()
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        onDismiss?()
        ignoresMouseEvents = true
        generation += 1
        let closing = generation
        closePopup(pivot: popupPivot(toward: anchor)) { [weak self] in
            guard let self, !self.isPresented, self.generation == closing else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.resetPopupScale()
            self.onClosed?()
        }
    }

    /// Beside the card toward the content, its top on the card's top, kept on the screen: right
    /// of the card, or left of it when the right has no room (a sidebar on the right), as
    /// NSPopover flipped. It never covers the card.
    private func place() {
        let size = CGSize(width: width, height: height)
        var origin = CGPoint(x: anchor.maxX + Metrics.space2, y: anchor.maxY - size.height)
        if let screen = parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame, margin = Metrics.space2
            if origin.x + size.width > visible.maxX - margin { origin.x = anchor.minX - Metrics.space2 - size.width }
            origin.x = max(origin.x, visible.minX + margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        setFrame(PopupStyle.standard.windowFrame(forCard: CGRect(origin: origin, size: size)), display: true)
    }
}

extension SidebarUpdateNotesPanel: ThemeResponsive {
    func themeDidChange() {
        glass.applyTheme()
    }
}
