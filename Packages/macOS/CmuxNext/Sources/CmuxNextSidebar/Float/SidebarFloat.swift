public import AppKit
public import CmuxNextDesign
import CmuxNextCompat

/// The floating sidebar in one window (`sidebar.floatOnHover`, Lawrence 2026-11-08: "if sidebar
/// is closed, we should have a toggleable mode, that will show a floating version of sidebar if
/// mouse moves to left"), as in Arc and Safari: with the sidebar hidden, the pointer resting on the
/// window's sidebar edge floats it over the content as a card (``SidebarContainerView/isFloatOverlay``).
///
/// The window owns one, installs it in its root view (``install(in:)``) and lays it out with the
/// root (``layout(in:rowHeight:sidebarHidden:side:cornerRadius:)``). It owns the two pointer zones
/// that feed ``reveal``: the edge zone (a thin strip on the sidebar edge, below the top row, whose
/// corner opens the toolbar band instead) and the card's zone (its full width plus a margin, fixed
/// for the whole float, so the slide never moves the edge under the pointer). While the sidebar
/// floats it follows menus (``MenuTracking``) and the app's presses (`SidebarFloatEvents`): a menu,
/// a held button or an edit in one of the sidebar's fields keeps it open, a press outside it closes it.
/// The window keeps its content where it is meanwhile (``onOverlayChange``).
@MainActor
public final class SidebarFloat {
    /// When the sidebar floats and closes (open and close delays, holds).
    public let reveal: FloatingSidebarReveal
    /// The thin strip on the window's sidebar edge (`.zero` while nothing may float).
    public let edgeZone: NSView = SidebarFloatZone(frame: .zero)
    /// The floating card's zone (`.zero` while the sidebar does not float).
    public let panelZone: NSView = SidebarFloatZone(frame: .zero)
    /// Whether the window lets its sidebar float now (not over Home, which has its own list on that
    /// edge, nor a page with the whole window).
    public var isAllowed: @MainActor () -> Bool = { true }
    /// The float started or its slide out landed: the window pins its content to the window edge
    /// while ``SidebarContainerView/isFloatOverlay`` holds, so nothing beside the card moves.
    public var onOverlayChange: (@MainActor () -> Void)?
    private let container: SidebarContainerView
    private let edgeReveal: HoverReveal
    private let panelReveal: HoverReveal
    private var menus: MenuTracking?
    private var menuDepth = 0
    private var events: SidebarFloatEvents?

    /// - Parameter container: The window's sidebar.
    /// - Parameter clock: Times the open and close delays (tests pass a manual clock).
    public init(container: SidebarContainerView, clock: any Clock<Duration> = ContinuousClock()) {
        self.container = container
        reveal = FloatingSidebarReveal(model: container.model, clock: clock)
        edgeReveal = HoverReveal(region: edgeZone)
        panelReveal = HoverReveal(region: panelZone)
        edgeReveal.onStateChange = { [weak self] state in self?.reveal.setEdgeEngaged(state.pointerInside) }
        panelReveal.onStateChange = { [weak self] state in self?.reveal.setPanelEngaged(state.pointerInside) }
        reveal.isEnabled = { DesignSettings.shared.sidebarSections.floatOnHover }
        reveal.isAllowed = { [weak self] in self?.isAllowed() ?? false }
        reveal.holdsOpen = { [weak self] in self?.isHeld ?? false }
        reveal.pointerInPanel = { [weak self] in self?.pointerInPanel ?? false }
        container.onFloatOverlayChange = { [weak self] floating in self?.overlayDidChange(floating) }
    }

    /// Adds the two zones to the window's root view (they take no clicks and draw nothing).
    /// - Parameter onOverlayChange: Sets ``onOverlayChange``.
    public func install(in host: NSView, onOverlayChange: (@MainActor () -> Void)? = nil) {
        for zone in [edgeZone, panelZone] { host.addSubview(zone) }
        self.onOverlayChange = onOverlayChange
    }

    /// Applies a change that can start or end a float: the setting, the window's content (Home), the sidebar's
    /// presentation, a page with the whole window.
    public func reconcile() { reveal.reconcile() }

    /// Places the zones in `host` (the root view) and gives the card the window's concentric radius.
    /// Also applies a change that can start or end a float (``reconcile()``): every one of them (the
    /// setting, the sidebar's presentation, a page with the whole window) lays the root out.
    public func layout(in host: NSView, rowHeight: CGFloat, sidebarHidden: Bool, side: SidebarSide, cornerRadius: CGFloat) {
        reveal.reconcile()
        let bounds = host.bounds, edgeWidth = FloatingSidebarReveal.edgeWidth
        let edge = sidebarHidden && reveal.canFloat
            ? CGRect(x: side == .left ? 0 : bounds.width - edgeWidth, y: 0, width: edgeWidth, height: max(0, bounds.height - rowHeight)) : .zero
        if edgeZone.frame != edge { edgeZone.frame = edge }
        var panel = CGRect.zero
        if container.isFloatOverlay || container.model.isFloating {
            let width = min(bounds.width, container.model.width + SidebarContainerView.floatInset + Self.panelMargin)
            panel = CGRect(x: side == .left ? 0 : bounds.width - width, y: 0, width: width, height: bounds.height)
        }
        if panelZone.frame != panel { panelZone.frame = panel }
        container.floatCornerRadius = cornerRadius
    }

    /// How far past the card's edge the pointer may go before the close delay starts.
    static let panelMargin: CGFloat = 8

    private func overlayDidChange(_ floating: Bool) {
        if floating, events == nil {
            menus = MenuTracking()
            menus?.subscribe { [weak self] change in
                guard let self else { return }
                switch change {
                case .began: menuDepth += 1
                case .ended: menuDepth = max(0, menuDepth - 1); reveal.reconcile()
                }
            }
            events = SidebarFloatEvents { [weak self] event in self?.saw(event) }
        } else if !floating {
            events?.stop()
            (events, menus, menuDepth) = (nil, nil, 0)
        }
        panelZone.superview?.needsLayout = true
        onOverlayChange?()
    }

    /// A press outside the card closes it at once (it was a glance; the press goes on to what it
    /// hit). A release or key up may end a hold (a drag, a rename), so the close delay starts again.
    private func saw(_ event: NSEvent) {
        guard reveal.isOpen else { return }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard menuDepth == 0 else { return }
            let inside = event.window === panelZone.window
                && panelZone.bounds.contains(panelZone.convert(event.locationInWindow, from: nil))
            if !inside { reveal.close() }
        default:
            reveal.reconcile()
        }
    }

    /// A menu, a held button (a drag) or the keyboard in one of the sidebar's fields (an inline
    /// rename, the search field) keeps the float open. Not a row's focus: a click on a row must
    /// not pin it.
    private var isHeld: Bool {
        if menuDepth > 0 || NSEvent.pressedMouseButtons != 0 { return true }
        guard let editor = container.window?.firstResponder as? NSTextView else { return false }
        let view = editor.isFieldEditor ? (editor.delegate as? NSView) ?? editor : editor
        return view.isDescendant(of: container)
    }

    private var pointerInPanel: Bool {
        guard let window = panelZone.window else { return false }
        return panelZone.bounds.contains(panelZone.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

/// A pointer zone of ``SidebarFloat``: tracks the pointer (its ``HoverReveal``), takes no clicks.
private final class SidebarFloatZone: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
