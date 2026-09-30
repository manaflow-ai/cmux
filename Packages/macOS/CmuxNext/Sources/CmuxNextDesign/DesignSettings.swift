public import CoreGraphics
public import Observation

/// Metrics a user may override individually on top of a density preset.
/// Raw values are the cmux.json keys under `appearance.metrics`.
public enum MetricKey: String, Sendable, CaseIterable, Codable {
    case sidebarWidth
    case sidebarRowHeight
    case tabStripHeight
    case tabMaxWidth
    case paletteRowHeight
    case columnGap
    case panelCornerRadius
    case chromeFontSize
}

/// Live, user-configurable design settings. The App fills this from
/// cmux.json (`appearance.density`, `appearance.metrics.*`) and from the
/// Settings window / palette; every Metrics and Typography read goes through
/// it, so changes apply to all surfaces without relaunch.
@Observable
public final class DesignSettings {
    public static let shared = DesignSettings()

    public var density: Density = .compact
    /// `ui.animationSpeed`: how fast chrome animates (see `Motion`).
    public var animationSpeed: MotionSpeed = .fast
    /// Per-metric overrides in points, clamped by `setOverride`.
    public private(set) var overrides: [MetricKey: CGFloat] = [:]
    /// Pane padding, corner radius and border from cmux.json `layout.*`,
    /// clamped by `setPaneChrome`.
    public private(set) var paneChrome = PaneChromeOverrides()
    /// `layout.centerFocusedColumn` (niri `center-focused-column`).
    public var centerFocusedColumn: CenterFocusedColumn = .never
    /// `layout.defaultColumnWidth`: new column width, a viewport fraction.
    public var defaultColumnWidth: Double = 0.5
    /// `focusRing.*`: the focused pane's ring or glow.
    public var focusRing = FocusRingSettings()
    /// `notifications.attention.*`: the unread pane's attention ring.
    public var attention = AttentionSettings()
    /// `window.titlebar`: minimal (no titlebar strip) or standard.
    public var titlebar: TitlebarStyle = .minimal

    public init() {}

    public func setOverride(_ key: MetricKey, _ value: CGFloat?) {
        guard let value else {
            overrides[key] = nil
            return
        }
        let range = Self.allowedRange(key)
        overrides[key] = min(max(value, range.lowerBound), range.upperBound)
    }

    public func setPaneChrome(_ value: PaneChromeOverrides) {
        let clamped = value.clamped
        if paneChrome != clamped { paneChrome = clamped }
    }

    public static func allowedRange(_ key: MetricKey) -> ClosedRange<CGFloat> {
        switch key {
        case .sidebarWidth: 160...420
        case .sidebarRowHeight: 20...48
        case .tabStripHeight: 22...44
        case .tabMaxWidth: 120...320
        case .paletteRowHeight: 26...48
        case .columnGap: 0...24
        case .panelCornerRadius: 0...20
        case .chromeFontSize: 10...16
        }
    }
}
