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
    public var rect: CGRect
    public var radius: CGFloat
    public var opacity: CGFloat

    public init(id: String, level: GlassLevel = .popover, rect: CGRect, radius: CGFloat = 0, opacity: CGFloat = 1) {
        self.id = id
        self.level = level
        self.rect = rect
        self.radius = radius
        self.opacity = opacity
    }

    /// The most a report carries (the page's `HOST_GLASS_MAX`).
    static let maximum = 16
    /// The longest id (the page's are `g<n>`).
    static let idMaximum = 32

    /// `[{id, level, left, top, right, bottom, radius?, opacity?}]`, or nil for anything else (a bad
    /// number, an unknown level, a repeated id, too many). Docked glass (`chrome`) is the window's own,
    /// never a floating surface, so it is refused too.
    static func decode(_ value: Any?) -> [AgentPaneHostGlassSurface]? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var surfaces: [AgentPaneHostGlassSurface] = []
        var ids = Set<String>()
        for item in list {
            guard let box = item as? [String: Any],
                  let id = box["id"] as? String, !id.isEmpty, id.count <= idMaximum, ids.insert(id).inserted,
                  let name = box["level"] as? String, let level = GlassLevel(rawValue: name), level != .chrome
            else { return nil }
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
                id: id, level: level,
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                radius: CGFloat(radius), opacity: CGFloat(opacity)
            ))
        }
        return surfaces
    }
}
