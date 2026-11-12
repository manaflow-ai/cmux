import CmuxNextDesign
import CoreGraphics

/// One value the Density Lab puts on a slider: a density field or an exact token, with the words a person reads.
struct DensityLabControl: Identifiable {
    enum Kind {
        /// `DensityTokens.level`.
        case level
        /// `DensityTokens.spacing`.
        case spacing
        /// `DensityTokens.fontSize` (nil follows the level).
        case fontSize
        /// `DensityTokens.tokens[name]` (nil follows the level); `metric` gives the automatic value.
        case token(String, metric: MetricTunable?)
    }

    let id: String
    let title: String
    let help: String
    let kind: Kind
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    /// The groups the lab shows, top to bottom.
    static let groups: [(title: String, controls: [DensityLabControl])] = [
        ("Overall", [
            DensityLabControl(id: "level", title: "Size", help: "Tighter to roomier. Moves every row, tab and icon together.",
                              kind: .level, range: DensityTokens.levelRange, step: 0.05, unit: ""),
            DensityLabControl(id: "spacing", title: "Padding", help: "Multiplies the space inside rows, tabs and panels.",
                              kind: .spacing, range: DensityTokens.spacingRange, step: 0.05, unit: "×"),
            DensityLabControl(id: "fontSize", title: "Text size", help: "The body text of the chrome. Auto follows Size.",
                              kind: .fontSize, range: DensityTokens.fontSizeRange, step: 0.5, unit: "pt"),
        ]),
        ("Sidebar icons", [
            token(.size, "Icon size", "How big every sidebar row icon draws: favicons, symbols, Home, pins.", 8...32, nil),
            token(.column, "Icon column", "The room the icon takes before the title starts.", 8...40, nil),
            token(.gap, "Gap to title", "Space between the icon column and the row title.", 0...24, nil),
            token(.inset, "Row padding", "Space from the row's edge to its icon (and to its last mark on the right).", 0...24, nil),
            token(.x, "Move left / right", "Shifts icons only; the titles stay.", -12...12, nil),
            token(.y, "Move up / down", "Shifts icons only. Positive moves down.", -8...8, nil),
        ]),
        ("Sidebar rows", [
            metric(MetricTunables.sidebarRowHeight, "Row height", 16...56),
            metric(MetricTunables.sidebarRowHeightWithSubtitle, "Row height, two lines", 28...80),
            metric(MetricTunables.sidebarHeaderHeight, "Header height", 16...56),
        ]),
        ("Tabs and toolbar", [
            metric(MetricTunables.titlebarHeight, "Titlebar height", 24...72),
            metric(MetricTunables.tabStripHeight, "Tab bar height", 20...64),
            metric(MetricTunables.tabHeight, "Tab height", 16...56),
            metric(MetricTunables.controlHeight, "Button and field height", 16...52),
            metric(MetricTunables.iconSize, "Toolbar and tab icons", 10...32),
            metric(MetricTunables.smallIconSize, "Small icons", 8...28),
            metric(MetricTunables.densityPaneCornerRadius, "Corner radius", 0...24),
        ]),
        ("Palette", [
            metric(MetricTunables.paletteRowHeight, "Palette row height", 20...60),
        ]),
    ]

    private static func token(_ name: SidebarIconTokens.Name, _ title: String, _ help: String, _ range: ClosedRange<Double>,
                              _ metric: MetricTunable?) -> DensityLabControl {
        DensityLabControl(id: name.rawValue, title: title, help: help, kind: .token(name.rawValue, metric: metric),
                          range: range, step: 0.5, unit: "pt")
    }

    private static func metric(_ tunable: MetricTunable, _ title: String, _ range: ClosedRange<Double>) -> DensityLabControl {
        DensityLabControl(id: tunable.name, title: title, help: tunable.descriptor.help, kind: .token(tunable.name, metric: tunable),
                          range: range, step: 1, unit: "pt")
    }

    /// The value `density` sets for this control, nil when it follows the level.
    func explicitValue(in density: DensityTokens) -> Double? {
        switch kind {
        case .level: density.level
        case .spacing: density.spacing
        case .fontSize: density.fontSize
        case .token(let name, _): density.tokens[name]
        }
    }

    /// The value drawn at `density` when the control is automatic; nil when the lab cannot know it (a sidebar rule).
    func automaticValue(in density: DensityTokens) -> Double? {
        switch kind {
        case .level, .spacing: return nil
        case .fontSize: return Double(density.levelBodySize)
        case .token(_, let metric?):
            let value = metric.glyph ? density.resolveGlyph(compact: metric.compact, comfortable: metric.comfortable)
                : density.resolve(compact: metric.compact, comfortable: metric.comfortable)
            return Double(value)
        case .token(let name, nil): return name == SidebarIconTokens.Name.x.rawValue || name == SidebarIconTokens.Name.y.rawValue ? 0 : nil
        }
    }

    /// `density` with this control set to `value` (nil: automatic; level and padding go back to 0 and 1).
    func applying(_ value: Double?, to density: DensityTokens) -> DensityTokens {
        var result = density
        switch kind {
        case .level: result.level = value ?? 0
        case .spacing: result.spacing = value ?? 1
        case .fontSize: result.fontSize = value
        case .token(let name, _): result.tokens[name] = value
        }
        return result
    }

    /// Whether the control can go back to automatic.
    var canBeAutomatic: Bool {
        if case .fontSize = kind { return true }
        if case .token = kind { return true }
        return false
    }
}
