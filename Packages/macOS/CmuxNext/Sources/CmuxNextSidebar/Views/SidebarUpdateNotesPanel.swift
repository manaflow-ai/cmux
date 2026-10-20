import AppKit
import CmuxNextDesign

/// The update card's highlights card (Leo 2026-10-13): a hover card like the workspace and tab
/// cards, not AppKit's NSPopover with its stock arrow. A borderless child window of the sidebar's
/// window holding the popup surface (themed glass, or the solid card under Reduce Transparency)
/// with its hairline and shadow (`Glass.makeOverlayPanel`, `PopupStyle`), beside the card toward
/// the content (left of it for a sidebar on the right, or with no room on the right) and
/// top-aligned with it, in the card's theme.
///
/// Motion and placement are the hover cards' own (Lawrence 2026-10-19, msg 2371: "the same
/// style, behavior, and styling ... Right now it has a different entry animation"): it used to
/// grow out of the card on the `.appear` spring (`openPopup`, the menu popup's scale-in) and
/// shrink back on close; now a first show fades in while it slides the last few points away from
/// the card, a hide fades out, and it sits at the hover cards' gap (`HoverCardMotion`). It takes clicks
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
    /// The card it opened from (screen), the target it sits beside.
    private var anchor: CGRect = .zero
    private var height: CGFloat = 1
    /// Bumped by every open and close, so a close that a reopen overtook keeps the panel.
    private var generation = 0
    /// The card sits left of the update card (no room on the right).
    private(set) var isLeading = false
    /// The entrance and exit: the workspace and tab cards' own.
    static let motion = HoverCardMotion.standard
    /// The window's clear band around the card: the shadow band plus the entrance's travel, so
    /// the slide never clips the shadow.
    private static var windowMargin: CGFloat { PopupStyle.standard.shadowMargin + motion.entryOffset }
    private weak var adoptedScope: ThemeScope?
    private var resignObserver: (any NSObjectProtocol)?

    init(width: CGFloat) {
        self.width = width
        host = SidebarPopoverIslandHost(width: width)
        glass = Glass.makeOverlayPanel(content: host, cornerRadius: PopupStyle.standard.cornerRadius)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        adoptPopupStyle(card: glass).travelMargin = Self.motion.entryOffset
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

    /// The card's frame on screen (the window less its clear band).
    var cardFrame: CGRect { frame.insetBy(dx: Self.windowMargin, dy: Self.windowMargin) }

    /// Shows the popup beside `anchor` (the card, screen coordinates) as a child of `parent`,
    /// `height` tall, drawn in `themeAnchor`'s theme.
    func present(beside anchor: CGRect, height: CGFloat, parent: NSWindow, themeAnchor: NSView) {
        // Read before `addChildWindow`, which orders the panel in: read after, a first show
        // looked already shown and skipped its entrance (the card popped in, msg 2371).
        let wasVisible = isVisible
        let reopening = !isPresented && wasVisible
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
        guard !wasVisible || reopening else { return }
        // A return during the fade-out fades back in where it is; a first show enters.
        if reopening { Self.motion.resume(self) } else { Self.motion.enter(self, placement: .beside, leading: isLeading) }
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
        Self.motion.exit(self) { [weak self] in
            guard let self, !self.isPresented, self.generation == closing else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.onClosed?()
        }
    }

    /// Beside the card toward the content, its top on the card's top, at the hover cards' gap
    /// (`HoverCardMotion.origin`), kept on the screen: right of the card, or left of it when the
    /// right has no room (a sidebar on the right), as NSPopover flipped. It never covers the card.
    private func place() {
        let size = CGSize(width: width, height: height)
        var origin = HoverCardMotion.origin(for: .beside, anchor: anchor, size: size)
        let gap = origin.x - anchor.maxX
        isLeading = false
        if let screen = parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame, margin = Metrics.space2
            if origin.x + size.width > visible.maxX - margin {
                origin.x = anchor.minX - gap - size.width
                isLeading = true
            }
            origin.x = max(origin.x, visible.minX + margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        let margin = Self.windowMargin
        setFrame(CGRect(origin: origin, size: size).insetBy(dx: -margin, dy: -margin), display: true)
    }
}

extension SidebarUpdateNotesPanel: ThemeResponsive {
    func themeDidChange() {
        glass.applyTheme()
    }
}
