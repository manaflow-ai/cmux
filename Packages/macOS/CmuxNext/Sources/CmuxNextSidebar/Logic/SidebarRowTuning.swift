public import CmuxNextDesign
public import CoreGraphics
import AppKit

/// Hand-tuned values of the sidebar's rows (Home, the pinned rows and the workspace list), each a Debug Settings
/// override of the token the rows already read (Lawrence 2026-11-12: "we need to build a ui to fix the ui so i can
/// hand tune the values"). The Sidebar Row Tuner (`debug.sidebarRowTuner`) shows exactly these, live; Debug Settings
/// lists them under Sidebar Rows.
///
/// Every number is a ``ComputedTunable``: with no override it is the value the density, the text size and the type
/// scale derive (the expression lives once, in its `derive`), so a tuned value never freezes the other densities.
/// In Release the store is inert and every read is its derived default.
public nonisolated struct SidebarRowTuning {
    public nonisolated init() {}
    /// The Debug Settings section, and the tuner's one list.
    public static let section = TunableSection(id: "sidebarRows", title: "Sidebar Rows", symbol: "sidebar.squares.left", order: 13)

    // MARK: Row box

    /// A one-line row's height, list and bands (Home, pinned rows) alike.
    public static let rowHeight = ComputedTunable(
        "sidebarRows.rowHeight", section, "Row height",
        help: "A one-line row's height: workspace rows, group headers, Home and the pinned rows.",
        range: 16...48, code: "SidebarRowTuning.rowHeight") { SidebarRowTokens.current.listRowHeight }
    /// The gap between two rows.
    public static let rowGap = ComputedTunable(
        "sidebarRows.rowGap", section, "Row gap",
        help: "The gap between two rows, list and bands; two lit fills keep it between them.",
        range: 0...12, code: "SidebarRowTuning.rowGap") { Metrics.space1 }
    /// The gap between a row's fill and the sidebar's edges.
    public static let outerInset = ComputedTunable(
        "sidebarRows.outerInset", section, "Fill to sidebar edge",
        help: "The gap between a row's fill and the sidebar's left and right edges.",
        range: 0...24, code: "SidebarRowTuning.outerInset") { SidebarDensityTokens.isComfortable ? Metrics.space4 : Metrics.space3 }
    /// The padding between a row's fill and its content.
    public static let contentInset = ComputedTunable(
        "sidebarRows.contentInset", section, "Fill to content",
        help: "Where a row's first glyph or text-only title starts inside its fill, and its last trailing mark ends.",
        range: 0...24, code: "SidebarRowTuning.contentInset") { SidebarDensityTokens.derivedContentInset }
    /// A row fill's corner radius.
    public static let cornerRadius = ComputedTunable(
        "sidebarRows.cornerRadius", section, "Fill corner radius",
        help: "The corner radius of every row fill: hover, selection, Home and the pinned rows.",
        range: 0...20, code: "SidebarRowTuning.cornerRadius") { Metrics.tabCornerRadius }
    /// The gap between two sections of the list.
    public static let sectionGap = ComputedTunable(
        "sidebarRows.sectionGap", section, "Section gap",
        help: "The room between two sections of the list (a heading and the rows above it).",
        range: 0...32, code: "SidebarRowTuning.sectionGap") { SidebarDensityTokens.isComfortable ? Metrics.space5 : Metrics.space4 }

    /// The gap between two bands above the list (Home and the pinned rows).
    public static let bandGap = ComputedTunable(
        "sidebarRows.bandGap", section, "Home to pinned gap",
        help: "The extra room between two bands above the list: Home, then the pinned rows.",
        range: 0...16, code: "SidebarRowTuning.bandGap") { Metrics.space2 }

    // MARK: Leading glyph

    /// The side every leading glyph's ink fills (``SidebarOpticalGlyph``).
    public static let glyphSize = ComputedTunable(
        "sidebarRows.glyphSize", section, "Glyph size",
        help: "The size every leading glyph's ink fills along its larger side: Home's house, a pin, a globe, a favicon.",
        range: 8...28, code: "SidebarRowTuning.glyphSize") {
            // A tab's icon box at the sidebar's defaults (Compact density, standard text), grown with its text size and
            // density as the workspace favicon grows (Lucas 2026-11-13: Helium's 16 pt favicon beside 12 pt text).
            let atDefaults = CGFloat.iconRowSize(forLabelPointSize: Typography.body.pointSize)
            return (Metrics.iconSize * SidebarStyle.workspaceFaviconSide / max(1, atDefaults)).rounded()
        }
    /// The leading icon column's width: a title after a glyph starts one gap after it.
    public static let iconColumn = ComputedTunable(
        "sidebarRows.iconColumn", section, "Icon column width",
        help: "The width of the leading icon column; a title after a glyph starts one gap after it.",
        range: 8...32, code: "SidebarRowTuning.iconColumn") {
            max(SidebarDensityTokens.isComfortable ? LayoutGrid.iconBoxComfortable : LayoutGrid.iconBox, SidebarStyle.iconBox)
        }
    /// The gap between the icon column and the title.
    public static let glyphGap = ComputedTunable(
        "sidebarRows.glyphGap", section, "Glyph to title gap",
        help: "The gap between the leading icon column and the title after it.",
        range: 0...20, code: "SidebarRowTuning.glyphGap") { LayoutGrid.gap }
    /// How strong a leading glyph draws.
    public static let glyphOpacity = Tunable<Double>.number(
        "sidebarRows.glyphOpacity", section, "Glyph opacity",
        help: "How strong every leading glyph draws (house, pin, globe, workspace icon), on top of its own ink.",
        default: 1, range: 0.2...1, step: 0.01, unit: .fraction, code: "SidebarRowTuning.glyphOpacity")

    // MARK: Text

    /// A row title's size.
    public static let titleSize = ComputedTunable(
        "sidebarRows.titleSize", section, "Title size",
        help: "A row title's point size (Home, pinned and workspace rows).",
        range: 9...20, step: 0.5, code: "SidebarRowTuning.titleSize") { SidebarStyle.derivedTitleFont.pointSize }
    /// A row title's weight.
    public static let titleWeight = Tunable<SidebarTunedWeight>.choice(
        "sidebarRows.titleWeight", section, "Title weight",
        help: "A row title's weight.", default: .regular, code: "SidebarRowTuning.titleWeight")
    /// How strong a row title draws.
    public static let titleOpacity = Tunable<Double>.number(
        "sidebarRows.titleOpacity", section, "Title opacity",
        help: "How strong a row title draws, on top of the theme's sidebar title ink.",
        default: 1, range: 0.2...1, step: 0.01, unit: .fraction, code: "SidebarRowTuning.titleOpacity")
    /// A section or list heading's size ("Workspaces", "Pinned").
    public static let headingSize = ComputedTunable(
        "sidebarRows.headingSize", section, "Heading size",
        help: "A section or list heading's point size (Workspaces, Pinned, a computer's name, a group's name).",
        range: 9...20, step: 0.5, code: "SidebarRowTuning.headingSize") { SidebarStyle.derivedHeaderFont.pointSize }
    /// A section or list heading's weight.
    public static let headingWeight = Tunable<SidebarTunedWeight>.choice(
        "sidebarRows.headingWeight", section, "Heading weight",
        help: "A section or list heading's weight.", default: .regular, code: "SidebarRowTuning.headingWeight")

    // MARK: Trailing

    /// Every status dot's diameter.
    public static let statusDot = ComputedTunable(
        "sidebarRows.statusDot", section, "Status dot size",
        help: "Every status dot's diameter: unread, needs you, done.",
        range: 4...14, code: "SidebarRowTuning.statusDot") { Metrics.space4 }

    /// The numbers, in the tuner's order.
    static var computed: [ComputedTunable] {
        [rowHeight, rowGap, outerInset, contentInset, cornerRadius, sectionGap, bandGap, glyphSize, iconColumn, glyphGap,
         titleSize, headingSize, statusDot]
    }

    /// Every tunable, in the tuner's order (box, glyph, text, trailing).
    public static var all: [TunableDescriptor] {
        [rowHeight.descriptor, rowGap.descriptor, outerInset.descriptor, contentInset.descriptor, cornerRadius.descriptor,
         sectionGap.descriptor, bandGap.descriptor, glyphSize.descriptor, iconColumn.descriptor, glyphGap.descriptor, glyphOpacity.descriptor,
         titleSize.descriptor, titleWeight.descriptor, titleOpacity.descriptor, headingSize.descriptor,
         headingWeight.descriptor, statusDot.descriptor]
    }

    /// Every override as set now, in one value: the sidebar lays its rows out again when it changes. Each read
    /// registers an Observation dependency on its key, so a tuner edit re-renders the sidebar.
    @MainActor static var signature: [String] {
        all.map { descriptor in TunableStore.shared.override(descriptor.key).map { "\($0)" } ?? "" }
    }
}

/// A row text weight the tuner offers.
public nonisolated enum SidebarTunedWeight: String, Sendable, CaseIterable, Hashable, TunableChoice {
    case light, regular, medium, semibold, bold

    public var tunableTitle: String { rawValue.capitalized }

    /// The AppKit weight.
    var font: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
