import AppKit
import CmuxNextDesign

/// The sidebar toggle's glyph (cx-uxdr, Lawrence 2026-10-08: "make more
/// choices in debug menu, come up with better designs"). A DEV and NIGHTLY
/// switch in Debug Settings (section "Sidebar and Window") and in the
/// Debug menu ("Sidebar Toggle Icon"); it changes the toggle in every
/// window at once. The default is `panel`, whose bar slides on click (Leo
/// 2026-11-09, from a reference recording).
///
/// SF Symbol candidates use system glyphs. Custom candidates are
/// `SidebarToggleGlyph` template images (CmuxNextDesign). Each candidate has a sidebar-shown and
/// a sidebar-hidden form: a filled rail (or a left chevron) means "the
/// sidebar is open, click to close"; an empty rail (or a right chevron)
/// means "click to open".
nonisolated enum SidebarToggleIcon: String, Sendable, CaseIterable, TunableChoice {
    /// A rounded panel whose inner bar slides: a full-height divider a third
    /// in while the sidebar shows, a short bar at the left edge while it is
    /// hidden. The bar slides between them with the sidebar (`slide`).
    case panel
    /// The arrow-into-panel glyph while shown, the sidebar glyph while hidden.
    case current
    /// SF Symbol `sidebar.left` in both states (the system toolbar glyph).
    case sidebarLeft
    /// SF Symbol `sidebar.squares.left` in both states.
    case sidebarSquares
    /// SF Symbol `rectangle.leftthird.inset.filled` in both states.
    case leftThird
    /// A thin panel outline with an inset filled left rail (empty when hidden).
    case railFilled
    /// The rail alone: a rounded bar, filled while shown, outlined while hidden.
    case railOnly
    /// A panel with a rail line and a chevron: left to close, right to open.
    case chevronPanel
    /// Two separate columns, a narrow one and a wide one; the narrow one fills.
    case twoColumn
    /// A panel whose rail holds three list rows (faint while hidden).
    case listRail
    /// A panel whose left edge is a thick bar (a thin divider while hidden).
    case thickEdge

    /// The Debug Settings switch (the Debug menu writes the same value).
    static let tunable = Tunable<SidebarToggleIcon>.choice(
        "sidebar.toggleIcon", .sidebar, "Sidebar toggle icon",
        help: "The glyph of the sidebar toggle right of the traffic lights. The panel's bar slides with the sidebar; the rest are earlier candidates.",
        default: .panel, code: "SidebarToggleIcon.tunable")

    /// `current` while the sidebar shows: collapse it to the left.
    static let currentCollapseSymbol = "rectangle.lefthalf.inset.filled.arrow.left"
    /// `current` while the sidebar is hidden: the sidebar.
    static let currentExpandSymbol = "sidebar.left"

    /// The prefix of the names `TitlebarBandButton.symbol` takes for a custom glyph.
    static let customPrefix = SidebarToggleGlyph.prefix

    /// Whether this candidate is drawn here (not an SF Symbol).
    var isCustom: Bool {
        switch self {
        case .current, .sidebarLeft, .sidebarSquares, .leftThird: false
        case .panel, .railFilled, .railOnly, .chevronPanel, .twoColumn, .listRail, .thickEdge: true
        }
    }

    /// Whether the glyph slides between its two forms as the sidebar opens and closes.
    var slides: Bool { self == .panel }

    /// The `panel` glyph `progress` of the way from its sidebar-shown form (0) to its hidden form (1).
    static func slideSymbol(progress: Double) -> String { SidebarToggleGlyph.slideName(progress: progress) }

    /// The glyph name for the sidebar's state: an SF Symbol name, or a
    /// `customPrefix` name `image(named:pointSize:)` draws.
    func symbol(sidebarHidden hidden: Bool) -> String {
        switch self {
        case .current: hidden ? Self.currentExpandSymbol : Self.currentCollapseSymbol
        case .sidebarLeft: "sidebar.left"
        case .sidebarSquares: "sidebar.squares.left"
        case .leftThird: "rectangle.leftthird.inset.filled"
        default: Self.customPrefix + rawValue + (hidden ? ".hidden" : ".shown")
        }
    }

    var tunableTitle: String {
        switch self {
        case .panel: String(localized: "sidebarToggleIcon.panel", defaultValue: "Panel with Sliding Bar", bundle: .module)
        case .current: String(localized: "sidebarToggleIcon.current", defaultValue: "Arrow (current)", bundle: .module)
        case .sidebarLeft: String(localized: "sidebarToggleIcon.sidebarLeft", defaultValue: "Sidebar", bundle: .module)
        case .sidebarSquares: String(localized: "sidebarToggleIcon.sidebarSquares", defaultValue: "Sidebar with Squares", bundle: .module)
        case .leftThird: String(localized: "sidebarToggleIcon.leftThird", defaultValue: "Left Third", bundle: .module)
        case .railFilled: String(localized: "sidebarToggleIcon.railFilled", defaultValue: "Panel with Filled Rail", bundle: .module)
        case .railOnly: String(localized: "sidebarToggleIcon.railOnly", defaultValue: "Rail Only", bundle: .module)
        case .chevronPanel: String(localized: "sidebarToggleIcon.chevronPanel", defaultValue: "Panel with Chevron", bundle: .module)
        case .twoColumn: String(localized: "sidebarToggleIcon.twoColumn", defaultValue: "Two Columns", bundle: .module)
        case .listRail: String(localized: "sidebarToggleIcon.listRail", defaultValue: "Rail with Rows", bundle: .module)
        case .thickEdge: String(localized: "sidebarToggleIcon.thickEdge", defaultValue: "Thick Edge", bundle: .module)
        }
    }

    // MARK: Custom glyphs

    /// A template image for a `customPrefix` name at `pointSize`, or nil
    /// for any other name (an SF Symbol). `SidebarToggleGlyph` draws it.
    static func image(named name: String, pointSize: CGFloat) -> NSImage? {
        guard let image = SidebarToggleGlyph.image(named: name, pointSize: pointSize) else { return nil }
        let parts = name.dropFirst(customPrefix.count).split(separator: ".")
        image.accessibilityDescription = parts.first.flatMap { SidebarToggleIcon(rawValue: String($0)) }?.tunableTitle
        return image
    }
}
