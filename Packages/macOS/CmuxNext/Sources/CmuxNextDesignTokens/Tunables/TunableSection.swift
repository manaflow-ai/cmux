public import Foundation

/// A sidebar section of the Debug Settings window. Modules declare their
/// tunables in one of these; `order` sorts the sidebar.
public nonisolated struct TunableSection: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    public let order: Int

    public init(id: String, title: String, symbol: String, order: Int) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.order = order
    }

    // Debug Settings is a developer tool in DEV and NIGHTLY builds only, so
    // section titles, labels and help are English developer text, not
    // localized (decision recorded in plans/cmux-next/debug-settings.md).

    public static let dropOverlay = TunableSection(id: "dropOverlay", title: "Drop Overlay", symbol: "square.dashed.inset.filled", order: 0)
    public static let tabDrag = TunableSection(id: "tabDrag", title: "Tab Drag", symbol: "hand.draw", order: 1)
    public static let tabs = TunableSection(id: "tabs", title: "Tabs", symbol: "rectangle.topthird.inset.filled", order: 2)
    public static let panes = TunableSection(id: "panes", title: "Panes and Columns", symbol: "rectangle.split.3x1", order: 3)
    public static let sidebar = TunableSection(id: "sidebar", title: "Sidebar and Window", symbol: "sidebar.left", order: 4)
    public static let palette = TunableSection(id: "palette", title: "Palette and Panels", symbol: "command", order: 5)
    public static let shape = TunableSection(id: "shape", title: "Shape and Icons", symbol: "app.dashed", order: 6)
    public static let springs = TunableSection(id: "springs", title: "Springs", symbol: "waveform.path", order: 7)
    public static let fades = TunableSection(id: "fades", title: "Fades and Loops", symbol: "circle.lefthalf.filled", order: 8)
    public static let hover = TunableSection(id: "hover", title: "Hover and Marquee", symbol: "cursorarrow.rays", order: 9)
    public static let glass = TunableSection(id: "glass", title: "Glass and Overlays", symbol: "drop", order: 10)
    public static let focus = TunableSection(id: "focus", title: "Focus and Scroll", symbol: "scope", order: 11)
    public static let status = TunableSection(id: "status", title: "Status Indicators", symbol: "progress.indicator", order: 12)
}
