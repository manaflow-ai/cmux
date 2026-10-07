public import CoreGraphics
public import Foundation

/// A density metric that Debug Settings can override. Its default is the
/// density preset (or the user's `appearance.metrics.*` override in
/// cmux.json); a Debug Settings override wins over both.
public nonisolated struct MetricTunable: Sendable {
    public let compact: CGFloat
    public let comfortable: CGFloat
    public let key: MetricKey?
    public let tunable: DerivedTunable<CGFloat>

    /// The value chrome uses now. Observation-tracked (density, cmux.json
    /// override and Debug Settings override).
    @MainActor public var value: CGFloat { Metrics.scale(tunable.resolve(Metrics.pick(compact, comfortable, key))) }
    public var descriptor: TunableDescriptor { tunable.descriptor }

    static func make(_ name: String, _ section: TunableSection, _ label: String, help: String,
                     compact: CGFloat, comfortable: CGFloat, key: MetricKey? = nil,
                     range: ClosedRange<Double>? = nil) -> MetricTunable {
        let upper = max((Double(comfortable) * 2.5).rounded(.up), 24)
        let step = comfortable < 10 ? 0.5 : 1
        let note = compact == comfortable ? "" : " Default \(TunableExport.format(Double(compact))) compact, \(TunableExport.format(Double(comfortable))) comfortable."
        let tunable = DerivedTunable<CGFloat>.number(
            "metrics.\(name)", section, label, help: help + note, range: range ?? 0...upper, step: step, unit: .points,
            code: "MetricTunables.\(name)") { Metrics.pick(compact, comfortable, key) }
        return MetricTunable(compact: compact, comfortable: comfortable, key: key, tunable: tunable)
    }
}

/// Every density metric and fixed chrome constant behind `Metrics`. The
/// literals here are the code defaults; `Metrics` reads them through these.
public nonisolated enum MetricTunables {
    // MARK: Sidebar and window

    public static let sidebarWidth = MetricTunable.make("sidebarWidth", .sidebar, "Sidebar width", help: "Default sidebar width when visible.",
                                                        compact: 208, comfortable: 240, key: .sidebarWidth, range: 120...480)
    public static let titlebarHeight = MetricTunable.make("titlebarHeight", .sidebar, "Titlebar height", help: "Height of the unified titlebar area.",
                                                          compact: 32, comfortable: 40, key: .titlebarHeight)
    public static let sidebarRowHeight = MetricTunable.make("sidebarRowHeight", .sidebar, "Sidebar row height", help: "A workspace row with one line.",
                                                            compact: 24, comfortable: 32, key: .sidebarRowHeight)
    public static let sidebarRowHeightWithSubtitle = MetricTunable.make(
        "sidebarRowHeightWithSubtitle", .sidebar, "Sidebar row height (subtitle)", help: "A workspace row with a cwd, branch or agent line.",
        compact: 36, comfortable: 46)
    public static let sidebarHeaderHeight = MetricTunable.make("sidebarHeaderHeight", .sidebar, "Sidebar header height", help: "Group and machine headers.",
                                                               compact: 22, comfortable: 26)
    public static let roomDotDiameter = MetricTunable.make("roomDotDiameter", .sidebar, "Room dot size", help: "Drawn size of a room dot at the sidebar bottom.",
                                                           compact: 5, comfortable: 6)
    public static let roomDotSlot = MetricTunable.make("roomDotSlot", .sidebar, "Room dot hit width", help: "Hit target width of each room dot.",
                                                       compact: 16, comfortable: 18)

    // MARK: Tabs

    public static let tabStripHeight = MetricTunable.make("tabStripHeight", .tabs, "Tab strip height", help: "Height of a pane's tab strip.",
                                                          compact: 28, comfortable: 36, key: .tabStripHeight)
    public static let tabHeight = MetricTunable.make("tabHeight", .tabs, "Tab height", help: "Height of a tab inside the strip.",
                                                     compact: 24, comfortable: 30)
    public static let tabMaxWidth = MetricTunable.make("tabMaxWidth", .tabs, "Tab max width", help: "Widest an unpinned tab gets.",
                                                       compact: 200, comfortable: 240, key: .tabMaxWidth)
    public static let tabMinWidth = MetricTunable.make("tabMinWidth", .tabs, "Tab min width", help: "Icon-only width (pinned and fully shrunk tabs).",
                                                       compact: 32, comfortable: 40)

    // MARK: Palette and panels

    public static let paletteRowHeight = MetricTunable.make("paletteRowHeight", .palette, "Palette row height", help: "One palette result row.",
                                                            compact: 32, comfortable: 40, key: .paletteRowHeight)
    public static let paletteSearchHeight = MetricTunable.make("paletteSearchHeight", .palette, "Palette search height", help: "The palette search field.",
                                                               compact: 44, comfortable: 52)
    public static let paletteWidth = MetricTunable.make("paletteWidth", .palette, "Palette width", help: "Width of the command palette.",
                                                        compact: 640, comfortable: 720, range: 360...1200)
    public static let panelInset = MetricTunable.make("panelInset", .palette, "Panel inset", help: "Inset between the window edge and floating glass panels.",
                                                      compact: 6, comfortable: 8)

    // MARK: Panes

    public static let columnGap = MetricTunable.make("columnGap", .panes, "Column gap", help: "Gap between strip columns.",
                                                     compact: 6, comfortable: 8, key: .columnGap)
    public static let densityPaneCornerRadius = MetricTunable.make(
        "densityPaneCornerRadius", .panes, "Pane corner radius", help: "Rounded pane corners when padding or a border shows and layout.paneCornerRadius is unset.",
        compact: 6, comfortable: 8)

    // MARK: Shape, icons, focus

    public static let panelCornerRadius = MetricTunable.make("panelCornerRadius", .shape, "Panel corner radius", help: "Floating glass panels and the floating drop highlight.",
                                                             compact: 10, comfortable: 12, key: .panelCornerRadius)
    public static let itemCornerRadius = MetricTunable.make("itemCornerRadius", .shape, "Item corner radius", help: "Tabs, rows and buttons.",
                                                            compact: 6, comfortable: 7)
    public static let iconSize = MetricTunable.make("iconSize", .shape, "Icon size", help: "Tab, row and toolbar icons.", compact: 14, comfortable: 16)
    public static let smallIconSize = MetricTunable.make("smallIconSize", .shape, "Small icon size", help: "Secondary glyphs and trailing buttons.",
                                                         compact: 12, comfortable: 14)
    public static let scrollEdgeFade = MetricTunable.make("scrollEdgeFade", .focus, "Scroll edge fade", help: "Height of the fade where a list hides content.",
                                                          compact: 18, comfortable: 22)

    static var metrics: [MetricTunable] {
        [sidebarWidth, titlebarHeight, sidebarRowHeight, sidebarRowHeightWithSubtitle, sidebarHeaderHeight, roomDotDiameter, roomDotSlot,
         tabStripHeight, tabHeight, tabMaxWidth, tabMinWidth, paletteRowHeight, paletteSearchHeight, paletteWidth, panelInset,
         columnGap, densityPaneCornerRadius, panelCornerRadius, itemCornerRadius, iconSize, smallIconSize, scrollEdgeFade]
    }
}
