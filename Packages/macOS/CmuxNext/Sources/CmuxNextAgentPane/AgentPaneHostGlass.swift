public import CmuxNextDesign
public import Foundation

/// The page's floating glass that the App draws under it (`pane.glass {surfaces}`; webviews
/// ui/glass/hostGlass.ts). Leo, 2026-11-06: "why the fuck is this not glass? Like the way the native
/// menus are. We can just do that, right? Like we're literally in Swift". A see-through Chromium page
/// cannot blur the window glass behind it, so a floating web glass read as a flat box; the page now
/// sends the boxes of the surfaces it marks, and the pane puts its own popover glass there, under the
/// page (AgentPaneView+HostGlass.swift). The page keeps every surface's content, layout and input.
/// Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneHostGlass {
    /// What the page last sent; empty while it marks nothing (or an older page).
    public private(set) var surfaces: [AgentPaneHostGlassSurface] = []
    /// Called when ``surfaces`` changes: the view draws them before the reply goes back.
    var onChange: (() -> Void)?
    /// The glass views by surface id (AgentPaneView+HostGlass.swift).
    var views: [String: OverlaySurfaceView] = [:]
    /// The view that holds them, under the page.
    var container: AgentPaneHostGlassContainer?

    func update(_ next: [AgentPaneHostGlassSurface]) {
        guard next != surfaces else { return }
        surfaces = next
        onChange?()
    }

    /// The page loaded again or ended: its surfaces went with it.
    func pageLoaded() {
        update([])
    }
}

/// One marked surface: its box in the page's viewport (CSS pixels), corner radius, glass level and
/// its own opacity (a fade the page runs).
public nonisolated struct AgentPaneHostGlassSurface: Equatable, Sendable {
    public var id: String
    public var level: GlassLevel
    /// The role's glass instead of the level's (`data-host-glass-role`, ``Glass/hostGlassRoles``).
    public var role: SurfaceRole?
    public var rect: CGRect
    public var radius: CGFloat
    public var opacity: CGFloat
    /// View points per CSS pixel the page measured ``rect`` at (the report's `zoom`, the zoom the page
    /// renders at); nil from a page that sends none, which the pane's own zoom then places.
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
    /// report's), never the pane's own value, which a Chromium page applies over another channel than
    /// its reports (cmux#42413: the glass apart from the menu after a zoom). `paneZoom`, the zoom the
    /// pane set, only for a page that sends none.
    func placementZoom(paneZoom: CGFloat) -> CGFloat {
        max(0.25, zoom ?? paneZoom)
    }

    /// The zooms a report may say it was measured at (the page zoom's range, with room).
    static let zoomRange: ClosedRange<Double> = 0.1...8

    /// The most a report carries (the page's `HOST_GLASS_MAX`).
    static let maximum = 16
    /// The longest id (the page's are `g<n>`).
    static let idMaximum = 32

    /// `[{id, level, role?, left, top, right, bottom, radius?, opacity?}]` measured at the report's
    /// `zoom` (absent from an older page), or nil for anything else (a bad number or zoom, an unknown
    /// level or role, a repeated id, too many). Docked glass (`chrome`) is the window's own, never a
    /// floating surface, so it is refused too.
    static func decode(_ value: Any?, zoom zoomValue: Any? = nil) -> [AgentPaneHostGlassSurface]? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var zoom: CGFloat?
        if let zoomValue {
            guard let number = (zoomValue as? NSNumber)?.doubleValue, zoomRange.contains(number) else { return nil }
            zoom = CGFloat(number)
        }
        var surfaces: [AgentPaneHostGlassSurface] = []
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
            surfaces.append(AgentPaneHostGlassSurface(
                id: id, level: level, role: role,
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                radius: CGFloat(radius), opacity: CGFloat(opacity), zoom: zoom
            ))
        }
        return surfaces
    }
}
