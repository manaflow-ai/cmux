public import AppKit
public import CmuxNextDesign

/// Host glass for any page (RFD 0207, "Host glass for pages"): a page marks a floating surface
/// `data-host-glass="<level>"` (webviews ui/glass/hostGlass.ts) and reports its box with
/// `cmux.app.glass {surfaces, zoom}` (webviews pages/shared/pageHostGlass.ts); the page view puts the
/// App's own glass of that level under it (``PageHostGlassLayer``), as the agent pane does with
/// `pane.glass`. Before, only the agent pane spoke host glass, so Settings, Feed and the other pages
/// drew their own blur. No page reports yet: nothing looks different until a page marks a surface.

/// One marked surface: its box in the page's viewport (CSS pixels), corner radius, glass level and
/// its own opacity (a fade the page runs). The agent pane's `pane.glass` reports decode to the same
/// type (`AgentPaneHostGlassSurface`).
public nonisolated struct PageHostGlassSurface: Equatable, Sendable {
    public var id: String
    public var level: GlassLevel
    /// The role's glass instead of the level's (`data-host-glass-role`, ``Glass/hostGlassRoles``).
    public var role: SurfaceRole?
    public var rect: CGRect
    public var radius: CGFloat
    public var opacity: CGFloat
    /// View points per CSS pixel the page measured ``rect`` at (the report's `zoom`, the zoom the page
    /// renders at); nil from a page that sends none, which the view's own zoom then places.
    public var zoom: CGFloat?

    public init(id: String, level: GlassLevel = .popover, role: SurfaceRole? = nil, rect: CGRect, radius: CGFloat = 0,
                opacity: CGFloat = 1, zoom: CGFloat? = nil) {
        self.id = id
        self.level = level
        self.role = role
        self.rect = rect
        self.radius = radius
        self.opacity = opacity
        self.zoom = zoom
    }

    /// The view points per CSS pixel this box is placed with: the zoom the page measured it at (its
    /// report's), never the view's own value, which a Chromium page applies over another channel than
    /// its reports (cmux#42413: the glass apart from the menu after a zoom). `paneZoom`, the zoom the
    /// view set, only for a page that sends none.
    public func placementZoom(paneZoom: CGFloat) -> CGFloat {
        max(0.25, zoom ?? paneZoom)
    }

    /// The zooms a report may say it was measured at (the page zoom's range, with room).
    public static let zoomRange: ClosedRange<Double> = 0.1...8

    /// The most a report carries (the page's `HOST_GLASS_MAX`).
    public static let maximum = 16
    /// The longest id (the page's are `g<n>`).
    public static let idMaximum = 32

    /// `[{id, level, role?, left, top, right, bottom, radius?, opacity?}]` measured at the report's
    /// `zoom` (absent from an older page), or nil for anything else (a bad number or zoom, an unknown
    /// level or role, a repeated id, too many). Docked glass (`chrome`) is the window's own, never a
    /// floating surface, so it is refused too.
    public static func decode(_ value: Any?, zoom zoomValue: Any? = nil) -> [PageHostGlassSurface]? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var zoom: CGFloat?
        if let zoomValue {
            guard let number = (zoomValue as? NSNumber)?.doubleValue, zoomRange.contains(number) else { return nil }
            zoom = CGFloat(number)
        }
        var surfaces: [PageHostGlassSurface] = []
        var ids = Set<String>()
        for item in list {
            guard let box = item as? [String: Any],
                  let id = box["id"] as? String, !id.isEmpty, id.count <= idMaximum, ids.insert(id).inserted,
                  let name = box["level"] as? String, let level = GlassLevel(rawValue: name), level != .chrome
            else { return nil }
            var role: SurfaceRole?
            if let named = box["role"] {
                guard let name = named as? String, let known = Glass.hostGlassRoles[name] else { return nil }
                role = known
            }
            let number = { (key: String) -> Double? in
                guard let value = (box[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) <= 100_000 else {
                    return nil
                }
                return value
            }
            guard let left = number("left"), let top = number("top"), let right = number("right"),
                  let bottom = number("bottom"), right >= left, bottom >= top else { return nil }
            let radius = box["radius"] == nil ? 0 : number("radius")
            let opacity = box["opacity"] == nil ? 1 : number("opacity")
            guard let radius, radius >= 0, let opacity, (0...1).contains(opacity) else { return nil }
            surfaces.append(PageHostGlassSurface(
                id: id, level: level, role: role,
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                radius: CGFloat(radius), opacity: CGFloat(opacity), zoom: zoom
            ))
        }
        return surfaces
    }
}

/// The App's glass under a page: one surface per reported box, in a view under the page's content
/// (``PageWebView/applyHostGlass(_:)``). Clipped to the page and never hit: the page above it takes
/// every click on its surfaces.
@MainActor
final class PageHostGlassLayer: NSView {
    private(set) var views: [String: (level: GlassLevel, role: SurfaceRole?, view: OverlaySurfaceView)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left, like the page's CSS boxes.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Makes, moves and removes the glass views for a report; `paneZoom` places a box from a page
    /// that sends no zoom.
    func apply(_ surfaces: [PageHostGlassSurface], paneZoom: CGFloat) {
        var kept = Set<String>()
        for surface in surfaces {
            kept.insert(surface.id)
            if let old = views[surface.id], old.level != surface.level || old.role != surface.role {
                old.view.removeFromSuperview()
                views[surface.id] = nil
            }
            let view: OverlaySurfaceView
            if let known = views[surface.id]?.view {
                view = known
            } else {
                // As the agent pane draws its host glass (AgentPaneView+HostGlass.swift).
                view = Glass.makeHostSurface(level: surface.level, role: surface.role)
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
                views[surface.id] = (surface.level, surface.role, view)
            }
            let zoom = surface.placementZoom(paneZoom: paneZoom)
            let frame = Self.frame(surface.rect, zoom: zoom)
            if view.frame != frame { view.frame = frame }
            let radius = surface.radius * zoom
            if view.cornerRadius != radius { view.cornerRadius = radius }
            if view.alphaValue != surface.opacity { view.alphaValue = surface.opacity }
        }
        for (id, entry) in views where !kept.contains(id) {
            entry.view.removeFromSuperview()
            views[id] = nil
        }
    }

    /// Re-tints the open glass for a theme change: each surface reads the theme of its scope again.
    func applyTheme() {
        for entry in views.values { entry.view.applyTheme() }
    }

    /// A viewport box (top-left CSS pixels) in this flipped view's points at `zoom`.
    nonisolated static func frame(_ rect: CGRect, zoom: CGFloat) -> CGRect {
        CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }
}
