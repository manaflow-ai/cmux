import AppKit
import CmuxNextDesign

/// The page's floating glass drawn by the App under the page (``AgentPaneHostGlass``; webviews
/// ui/glass/hostGlass.ts). Each surface the page marks gets the App's own glass surface of its level
/// (`Glass.makeSurface`: Liquid Glass on macOS 26, the vibrancy blur before, the opaque popup surface
/// under Reduce Transparency), at the surface's box, in a view under the page. The page is see-through
/// there, so the glass shows through it with the page's content on top, the way a native popover
/// draws its own views on its glass.
extension AgentPaneView {
    /// Follows the page's reports for as long as the view lives (called once from init).
    func installHostGlass() {
        model.hostGlass.onChange = { [weak self] in self?.layoutHostGlass() }
        // Interface Scale changed the page's zoom (Cmd +/- comes through ``applyZoom``).
        page?.onZoomChange = { [weak self] in self?.pageZoomChanged() }
    }

    /// View points per CSS pixel for a box the page measured at `reported` (webviews
    /// ui/visualViewportBox.ts `pageZoom`), or at the pane's zoom now for an older page's box. Drawn at
    /// the zoom it was measured at, a page box stays on its content across a zoom (Leo, 2026-11-12, of
    /// the "Also working here" popover: "evidently you zoom in and it doesn't really, you know, it
    /// doesn't follow, right?"); the page measures again at the new zoom and that report moves it.
    func pageBoxZoom(_ reported: CGFloat?) -> CGFloat {
        max(0.25, reported ?? CGFloat(uiPointerPageZoom))
    }

    /// The page's zoom changed: every box the App draws from the page is placed again (an older
    /// page's at the new zoom; a newer page's report at the new zoom follows).
    func pageZoomChanged() {
        layoutSessionInfo()
        layoutHostGlass()
        toastAvoidanceMoved()
    }

    /// Makes, moves and removes the glass views for the page's last report, in the page's frame.
    func layoutHostGlass() {
        let holder = model.hostGlass
        guard !holder.surfaces.isEmpty else {
            for view in holder.views.values { view.removeFromSuperview() }
            holder.views = [:]
            holder.container?.removeFromSuperview()
            holder.container = nil
            return
        }
        let pageView: NSView = page ?? webView
        let container = holder.container ?? makeHostGlassContainer(below: pageView)
        if container.frame != pageView.frame { container.frame = pageView.frame }
        let bounds = CGRect(origin: .zero, size: container.frame.size)
        var kept = Set<String>()
        for surface in holder.surfaces {
            kept.insert(surface.id)
            let view = holder.views[surface.id] ?? makeHostGlassView(surface, in: container)
            let zoom = pageBoxZoom(surface.zoom)
            let frame = Self.hostGlassFrame(surface.rect, page: bounds, zoom: zoom, flipped: container.isFlipped)
            if view.frame != frame { view.frame = frame }
            let radius = surface.radius * zoom
            if view.cornerRadius != radius { view.cornerRadius = radius }
            if view.alphaValue != surface.opacity { view.alphaValue = surface.opacity }
        }
        for (id, view) in holder.views where !kept.contains(id) {
            view.removeFromSuperview()
            holder.views[id] = nil
        }
    }

    /// Re-tints the open glass for a theme change (`applyTheme`): each surface reads the theme of its scope again.
    func themeHostGlass() {
        for view in model.hostGlass.views.values { view.applyTheme() }
    }

    private func makeHostGlassContainer(below pageView: NSView) -> AgentPaneHostGlassContainer {
        let container = AgentPaneHostGlassContainer(frame: pageView.frame)
        // Under the page: its see-through pixels show the glass, and its content draws on top.
        addSubview(container, positioned: .below, relativeTo: pageView)
        model.hostGlass.container = container
        return container
    }

    private func makeHostGlassView(_ surface: AgentPaneHostGlassSurface, in container: NSView) -> OverlaySurfaceView {
        let view = Glass.makeSurface(Self.hostGlassRole(surface.level), interactive: false)
        view.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(view)
        model.hostGlass.views[surface.id] = view
        return view
    }

    /// The overlay role whose glass a level draws: popovers and menus their own, chips a tooltip's.
    static func hostGlassRole(_ level: GlassLevel) -> SurfaceRole {
        switch level {
        case .menu: .menu
        case .chip: .tooltip
        case .chrome, .popover: .popover
        }
    }

    /// A surface's viewport box (top-left CSS pixels) in a page frame `page` at `zoom`, in the
    /// coordinates `page` is in.
    static func hostGlassFrame(_ rect: CGRect, page: CGRect, zoom: CGFloat, flipped: Bool) -> CGRect {
        sessionInfoOverlayRect(rect, page: page, zoom: zoom, flipped: flipped)
    }
}

/// The view under the page that holds the host glass: clipped to the page, and never hit (the page
/// above it takes every click on the surfaces).
final class AgentPaneHostGlassContainer: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
