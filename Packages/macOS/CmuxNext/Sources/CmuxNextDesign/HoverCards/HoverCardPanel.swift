public import AppKit

/// Where a card sits relative to its target.
public enum HoverCardPlacement: Sendable {
    /// Under the target, left-aligned (tab strips).
    case below
    /// Over the target, left-aligned (a tab strip at the bottom, R109).
    case above
    /// Right of the target, top-aligned (sidebar rows).
    case beside
}

/// The one hover card window of the app: a borderless, non-activating,
/// click-through child window holding a glass card (opaque under Reduce
/// Transparency, `OverlaySurfaceView`). The coordinator owns
/// the only instance and swaps the card's body (a tab card or a workspace
/// card view, each reused) into it.
@MainActor
final class HoverCardPanel: NSPanel {
    /// Live instances (the debug single-card check counts them).
    nonisolated(unsafe) static var liveInstances = 0

    /// The card's material; its `contentView` holds the body.
    let glass: OverlaySurfaceView
    private weak var body: NSView?
    private weak var parentWindowRef: NSWindow?
    private var anchor: CGRect = .zero
    private var placement: HoverCardPlacement = .below
    private var applyTheme: (() -> Void)?
    /// The scope the card draws in; a retarget within it adopts nothing again.
    private weak var adoptedScope: ThemeScope?

    init() {
        glass = Glass.makeOverlayPanel(cornerRadius: Metrics.panelCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        Self.liveInstances += 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // A no-activate test run is never active; its cards must still show.
        hidesOnDeactivate = !WindowPlacement.noActivate
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass
    }

    isolated deinit { Self.liveInstances -= 1 }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card is on screen (fading in or shown), not fading out.
    var isShowingCard: Bool { isVisible && parentWindowRef != nil && !isDismissing }
    private var isDismissing = false

    /// Shows `body` at `anchor` (screen) as a child of `parent`. `themeAnchor`
    /// is the view the card describes; the card draws in its theme scope.
    /// `sliding` (a retarget of a visible card) moves it in the same frame
    /// like any other placement; only a first show fades in.
    func present(body newBody: NSView, anchor: CGRect, placement: HoverCardPlacement, parent: NSWindow,
                 themeAnchor: NSView?, sliding: Bool, applyTheme: @escaping () -> Void) {
        let wasDismissing = isDismissing
        isDismissing = false
        if body !== newBody {
            body?.removeFromSuperview()
            newBody.translatesAutoresizingMaskIntoConstraints = false
            let container = glass.contentView
            container.addSubview(newBody)
            NSLayoutConstraint.activate([
                newBody.topAnchor.constraint(equalTo: container.topAnchor),
                newBody.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                newBody.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                newBody.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            body = newBody
        }
        // The card draws in the theme scope of the view it describes and
        // follows that scope's changes while it shows, at full strength even
        // over an unfocused pane's subtle strip.
        let scope = (themeAnchor?.themeScope ?? parent.themeScope).fullStrength
        self.applyTheme = applyTheme
        if adoptedScope !== scope {
            scope.adopt(self)
            scope.addResponder(self)
            adoptedScope = scope
            themeDidChange()
        } else {
            applyTheme()
        }
        if parentWindowRef !== parent {
            parentWindowRef?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            parentWindowRef = parent
        }
        self.anchor = anchor
        self.placement = placement
        place()
        // A fade-out in flight (hide and show in one turn) is replaced by a fade-in.
        if !isVisible || alphaValue < 1 || wasDismissing {
            if !isVisible { alphaValue = 0 }
            orderFront(nil)
            Motion.animateTimed(.fadeIn, in: contentView) { animator().alphaValue = 1 }
        }
    }

    /// Recolors the glass and the body in the card's theme scope.
    func themeDidChange() {
        glass.applyTheme()
        applyTheme?()
    }

    /// The target moved: the card follows it at once.
    func follow(_ newAnchor: CGRect) {
        guard newAnchor != anchor, isShowingCard else { return }
        anchor = newAnchor
        place()
    }

    /// The body's size changed (a resources row appeared).
    func refit() {
        guard isShowingCard else { return }
        place()
    }

    private func place() {
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        var origin = Self.origin(for: placement, anchor: anchor, size: size)
        if let screen = parentWindowRef?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin = Metrics.space2
            origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
            origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        }
        // R131: a retarget moves the card in the same frame (Chrome); a
        // window-frame slide restarted on every tab trailed the pointer.
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        Motion.animateTimed(.fadeOut, in: contentView, { animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.isDismissing else { return }
            self.isDismissing = false
            self.parentWindowRef?.removeChildWindow(self)
            self.parentWindowRef = nil
            self.orderOut(nil)
        })
    }
}

extension HoverCardPanel: ThemeResponsive {}

extension HoverCardPanel {
    /// The card's origin (screen coordinates, y up) for `placement` next to
    /// `anchor`, before the screen clamp.
    static func origin(for placement: HoverCardPlacement, anchor: CGRect, size: CGSize) -> CGPoint {
        switch placement {
        case .below: CGPoint(x: anchor.minX, y: anchor.minY - Metrics.space2 - size.height)
        case .above: CGPoint(x: anchor.minX, y: anchor.maxY + Metrics.space2)
        case .beside: CGPoint(x: anchor.maxX + Metrics.space2, y: anchor.maxY - size.height)
        }
    }
}
