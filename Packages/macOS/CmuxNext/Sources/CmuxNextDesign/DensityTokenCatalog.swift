public import CoreGraphics
public import Foundation

/// Every value a density sets, as the Density Playground lists it (Lawrence 2026-11-17: "make a density playground cmd
/// shift p thing so i can fine tune every aspect of density, in terms of vertical and horizontal tabs, and also create
/// new densities"). Each entry is one key of ``DensityTokens/tokens`` (or the density's spacing or body text
/// size) with its group, label, range and step, and how to read its value when the density does not set it.
///
/// The catalog edits a density, never Debug Settings overrides: a tuned value is part of the density, saves to
/// `appearance.customDensities` and works in every build.
///
/// ```swift
/// let entry = DensityTokenCatalog.entry("sidebarRowGap")!
/// var mine = DensityPreset.cozy.tokens
/// mine = DensityTokenCatalog.setting(entry, to: 4, in: mine)   // tokens["sidebarRowGap"] == 4
/// DensityTokenCatalog.explicitValue(entry, in: mine)            // 4
/// ```
public nonisolated struct DensityTokenCatalog: Sendable {
    public init() {}

    /// The playground's three groups.
    public enum Group: String, Sendable, CaseIterable, Hashable {
        case verticalTabs
        case horizontalTabs
        case other

        /// The group's heading (English developer text, as every tunable label).
        public var title: String {
            switch self {
            case .verticalTabs: "Vertical tabs"
            case .horizontalTabs: "Horizontal tabs"
            case .other: "Other"
            }
        }
    }

    /// What an entry stores.
    public enum Field: Sendable, Hashable {
        /// `tokens[key]`.
        case token
        /// ``DensityTokens/spacing``.
        case spacing
        /// ``DensityTokens/fontSize`` (nil follows the density's level).
        case fontSize
    }

    /// How an entry's number reads.
    public enum Unit: Sendable, Hashable {
        case points
        /// A multiplier ("1.10×").
        case factor
    }

    /// One tunable value of a density.
    public struct Entry: Sendable, Identifiable {
        /// The token name (`sidebarRowGap`), or `spacing` and `fontSize` for those two fields.
        public let key: String
        public let field: Field
        public let group: Group
        /// The subheading inside the group ("Sidebar rows", "Pane tab list").
        public let section: String
        public let label: String
        public let help: String
        public let range: ClosedRange<Double>
        public let step: Double
        public let unit: Unit
        /// The value chrome draws when the density does not set this token, in unscaled points (Interface Size
        /// divided out). Nil when only a module above Design can read it: the app supplies those
        /// (``DensityTokenCatalog/entries(fallbacks:)``).
        public var fallback: (@MainActor @Sendable () -> CGFloat)?

        public var id: String { key }

        init(_ key: String, _ group: Group, _ section: String, _ label: String, help: String, range: ClosedRange<Double>,
             step: Double = 0.5, unit: Unit = .points, field: Field = .token, fallback: (@MainActor @Sendable () -> CGFloat)? = nil) {
            self.key = key
            self.field = field
            self.group = group
            self.section = section
            self.label = label
            self.help = help
            self.range = range
            self.step = step
            self.unit = unit
            self.fallback = fallback
        }
    }

    // MARK: Reading and writing

    /// The value `density` sets for `entry`, nil when it derives it (a token it does not set, or no `fontSize`).
    public static func explicitValue(_ entry: Entry, in density: DensityTokens) -> Double? {
        switch entry.field {
        case .token: density.tokens[entry.key]
        case .spacing: density.spacing
        case .fontSize: density.fontSize
        }
    }

    /// The value `entry` has at `density`: its own when set, else what chrome derives for it at that density
    /// (`scoped` runs `entry.fallback` with `density` as ``DensityTokens/scoped``), else the token of the built-in it
    /// was made from, else nil.
    @MainActor public static func value(_ entry: Entry, in density: DensityTokens,
                                        scoped: (_ fallback: @MainActor () -> CGFloat) -> CGFloat) -> Double? {
        if let explicit = explicitValue(entry, in: density) { return explicit }
        if entry.field == .fontSize { return Double(density.bodySize) }
        if let fallback = entry.fallback { return Double(scoped(fallback) / max(Metrics.scale(1), 0.01)) }
        return entry.field == .token ? base(of: density).tokens[entry.key] : nil
    }

    /// `density` with `entry` set to `value`, clamped into the entry's range and snapped to its step's grid.
    public static func setting(_ entry: Entry, to value: Double, in density: DensityTokens) -> DensityTokens {
        guard value.isFinite else { return density }
        let clamped = min(max(value, entry.range.lowerBound), entry.range.upperBound)
        let snapped = entry.step > 0 ? (clamped / entry.step).rounded() * entry.step : clamped
        var tokens = density.tokens
        var spacing = density.spacing, fontSize = density.fontSize
        switch entry.field {
        case .token: tokens[entry.key] = snapped
        case .spacing: spacing = snapped
        case .fontSize: fontSize = snapped
        }
        return DensityTokens(id: density.id, name: density.name, basedOn: density.basedOn, level: density.level, spacing: spacing,
                             fontSize: fontSize, tokens: tokens)
    }

    /// `density` with `entry` back at `base`'s: `base`'s own value, or unset when `base` derives it.
    public static func resetting(_ entry: Entry, in density: DensityTokens, to base: DensityTokens) -> DensityTokens {
        var tokens = density.tokens
        var spacing = density.spacing, fontSize = density.fontSize
        switch entry.field {
        case .token: tokens[entry.key] = base.tokens[entry.key]
        case .spacing: spacing = base.spacing
        case .fontSize: fontSize = base.fontSize
        }
        return DensityTokens(id: density.id, name: density.name, basedOn: density.basedOn, level: density.level, spacing: spacing,
                             fontSize: fontSize, tokens: tokens)
    }

    /// `density` with every value back at `base`'s, keeping its own id, name and origin.
    public static func resettingAll(_ density: DensityTokens, to base: DensityTokens) -> DensityTokens {
        DensityTokens(id: density.id, name: density.name, basedOn: density.basedOn, level: base.level, spacing: base.spacing,
                      fontSize: base.fontSize, tokens: base.tokens)
    }

    /// Whether `entry` differs between `density` and `base` (by what each sets, so a value set equal to the derived
    /// one is not a change).
    public static func differs(_ entry: Entry, _ density: DensityTokens, from base: DensityTokens) -> Bool {
        let mine = explicitValue(entry, in: density), theirs = explicitValue(entry, in: base)
        switch (mine, theirs) {
        case (nil, nil): return false
        case let (a?, b?): return abs(a - b) > 0.0001
        default: return true
        }
    }

    /// The built-in `density` was made from (itself for a built-in), the base its values reset to; Default when it
    /// names none.
    public static func base(of density: DensityTokens) -> DensityTokens {
        if let preset = DensityPreset(rawValue: density.id) { return preset.tokens }
        if let basedOn = density.basedOn, let preset = DensityPreset(rawValue: basedOn) { return preset.tokens }
        return DensityPreset.cozy.tokens
    }

    // MARK: The entries

    /// A module's fallbacks by key: what it draws for each value a density does not set.
    public typealias Fallbacks = [String: @MainActor @Sendable () -> CGFloat]

    /// Every entry, in the playground's order, with the modules' `fallbacks` (by key) filled in for entries Design
    /// cannot read (the sidebar's, the tab strip's and the omnibar's).
    public static func entries(fallbacks: [Fallbacks] = []) -> [Entry] {
        all.map { entry in
            var entry = entry
            if let fallback = fallbacks.lazy.compactMap({ $0[entry.key] }).first { entry.fallback = fallback }
            return entry
        }
    }

    /// The entry for `key`.
    public static func entry(_ key: String) -> Entry? { all.first { $0.key == key } }

    private static let sidebar = "Sidebar rows", paneList = "Pane tab list", strip = "Tab strip", tab = "Tab content"
    private static let scale = "Scale", toolbar = "Toolbar and omnibar", palette = "Command palette", chat = "Chats", window = "Window and panes"

    private static func metric(_ tunable: MetricTunable) -> @MainActor @Sendable () -> CGFloat { { tunable.value } }

    /// Every entry, in order: vertical tabs, horizontal tabs, other.
    public static let all: [Entry] = [
        // Vertical tabs: the sidebar's rows.
        Entry("sidebarRowHeight", .verticalTabs, sidebar, "Row height", help: "A one-line workspace row; sets the room above and below the title.",
              range: 14...56, fallback: metric(MetricTunables.sidebarRowHeight)),
        Entry("sidebarRowGap", .verticalTabs, sidebar, "Row gap", help: "The gap between two rows.", range: 0...12),
        Entry("sidebarRowInset", .verticalTabs, sidebar, "Row to sidebar edge", help: "The gap between a row's fill and the sidebar's left and right edges.", range: 0...24),
        Entry("sidebarContentInset", .verticalTabs, sidebar, "Horizontal padding", help: "Where a row's icon starts inside its fill.", range: 0...24),
        Entry("sidebarCornerRadius", .verticalTabs, sidebar, "Corner radius", help: "Every row fill's corner: hover, selection, Home and pinned rows.", range: 0...20),
        Entry("sidebarIconColumn", .verticalTabs, sidebar, "Icon column", help: "The leading icon column's width.", range: 8...32),
        Entry("sidebarGlyphInk", .verticalTabs, sidebar, "Icon size", help: "The ink of every leading glyph and favicon.", range: 6...28,
              fallback: { Metrics.tabIconSize * 11 / 16 }),
        Entry("sidebarIconGap", .verticalTabs, sidebar, "Icon to title", help: "The gap between the icon column and the title.", range: 0...20),
        Entry("sidebarTitleSize", .verticalTabs, sidebar, "Title size", help: "A row title's point size.", range: 9...20, step: 0.25,
              fallback: { Typography.sidebarTitleSize(Metrics.tokens) }),
        Entry("sidebarGroupIndent", .verticalTabs, sidebar, "Group indent", help: "How far a nested group's rows step in per level.", range: 0...32),
        Entry("sidebarHeaderHeight", .verticalTabs, sidebar, "Section header height", help: "A computer's or section's header row.", range: 12...48,
              fallback: metric(MetricTunables.sidebarHeaderHeight)),
        Entry("sidebarHeadingSize", .verticalTabs, sidebar, "Heading size", help: "Group and section heading text.", range: 9...20, step: 0.25),
        Entry("sidebarSectionGap", .verticalTabs, sidebar, "Section gap", help: "The room between two sections of the list.", range: 0...32),
        Entry("sidebarBandGap", .verticalTabs, sidebar, "Home to pinned gap", help: "The extra room between Home and the pinned rows.", range: 0...16),
        Entry("sidebarStatusDot", .verticalTabs, sidebar, "Status dot", help: "Unread, needs-you and done dots.", range: 4...14),
        Entry("sidebarWidth", .verticalTabs, sidebar, "Sidebar width", help: "The sidebar's default width.", range: 120...480, step: 1,
              fallback: metric(MetricTunables.sidebarWidth)),
        // Vertical tabs: a pane's own vertical tab list (tabs.verticalTabs).
        Entry("verticalTabRowHeight", .verticalTabs, paneList, "Row height", help: "A tab row in a pane's vertical tab list.", range: 14...56),
        Entry("verticalTabRowGap", .verticalTabs, paneList, "Row gap", help: "The gap between two tab rows.", range: 0...12),
        Entry("verticalTabPadding", .verticalTabs, paneList, "Horizontal padding", help: "The rows' inset from the list's edges.", range: 0...24),
        Entry("verticalTabIconSize", .verticalTabs, paneList, "Icon size", help: "A tab row's favicon.", range: 8...28),
        Entry("verticalTabHeaderHeight", .verticalTabs, paneList, "Group header height", help: "A tab group's header row.", range: 12...48),
        Entry("verticalTabIndent", .verticalTabs, paneList, "Group indent", help: "How far a group's tabs sit in, room for its line.", range: 0...24),
        Entry("verticalTabCornerRadius", .verticalTabs, paneList, "Corner radius", help: "A tab row's fill corner.", range: 0...20),
        Entry("verticalTabTileSize", .verticalTabs, paneList, "Pinned tile size", help: "A pinned tab's square tile.", range: 16...56),
        Entry("verticalTabWidth", .verticalTabs, paneList, "List width", help: "The list's width while it shows titles.", range: 120...480, step: 1),
        // Horizontal tabs: the strip.
        Entry("browserRowHeight", .horizontalTabs, strip, "Tab height", help: "A tab pill's height; the omnibar takes it too.", range: 16...48,
              fallback: { Metrics.tabHeight }),
        Entry("browserRowGap", .horizontalTabs, strip, "Strip padding", help: "The gap above and below the tabs (the strip's height is the tab plus twice this).",
              range: 0...12, fallback: { Metrics.browserRowGap ?? max(0, (Metrics.tabStripHeight - Metrics.tabHeight) / 2) }),
        Entry("tabStripEndGap", .horizontalTabs, strip, "Strip end insets", help: "From the strip's start to the first tab, and from the last tab to +.",
              range: 0...24, fallback: { Metrics.tabStripEndGap }),
        Entry("tabGap", .horizontalTabs, strip, "Gap between tabs", help: "The gap between two tab pills.", range: 0...16,
              fallback: { Metrics.tabBackgroundInset * 2 }),
        Entry("tabMinActiveWidth", .horizontalTabs, strip, "Min width (selected)", help: "Narrowest the selected tab gets when crowded; never under its icon and close button.",
              range: 32...320, step: 1,
              fallback: metric(MetricTunables.tabMinActiveWidth)),
        Entry("tabMinInactiveWidth", .horizontalTabs, strip, "Min width (others)", help: "Narrowest the other tabs get before the strip scrolls.", range: 16...320,
              step: 1, fallback: { Metrics.tabMinInactiveWidth }),
        Entry("tabMaxWidth", .horizontalTabs, strip, "Max width", help: "Widest a tab gets.", range: 60...480, step: 1, fallback: metric(MetricTunables.tabMaxWidth)),
        Entry("tabPinnedWidth", .horizontalTabs, strip, "Pinned tab width", help: "A pinned tab's width.", range: 24...120, step: 1,
              fallback: metric(MetricTunables.tabPinnedWidth)),
        Entry("tabCornerRadius", .horizontalTabs, strip, "Corner radius", help: "A tab pill's corner.", range: 0...20, fallback: { Metrics.tabCornerRadius }),
        // Horizontal tabs: inside a tab.
        Entry("tabIconLeading", .horizontalTabs, tab, "Leading padding", help: "From the pill's leading edge to its icon.", range: 0...20,
              fallback: { Metrics.tabContentLeadingInset }),
        Entry("tabIconSize", .horizontalTabs, tab, "Icon size", help: "A tab's favicon box.", range: 8...28, fallback: { Metrics.tabIconSize }),
        Entry("tabIconTitleGap", .horizontalTabs, tab, "Icon to title", help: "The gap between a tab's icon and its title.", range: 0...16),
        Entry("tabTitleSize", .horizontalTabs, tab, "Title size", help: "A tab title's point size.", range: 9...20, step: 0.25,
              fallback: { Typography.tabTitleSize(Metrics.tokens) }),
        Entry("tabTitleDrop", .horizontalTabs, tab, "Title baseline shift", help: "Moves the title down from optical center.", range: 0...4, step: 0.25,
              fallback: { 0 }),
        Entry("tabCloseSize", .horizontalTabs, tab, "Close button", help: "The x's hover square.", range: 4...28,
              fallback: { BrowserChromeTuning.value(.closeSize) }),
        Entry("tabCloseGlyphSize", .horizontalTabs, tab, "Close glyph", help: "The x's ink.", range: 4...28, fallback: { BrowserChromeTuning.value(.closeInk) }),
        Entry("tabCloseCornerRadius", .horizontalTabs, tab, "Close corner", help: "The x's hover square corner.", range: 0...14,
              fallback: { BrowserChromeTuning.value(.closeCorner) }),
        Entry("tabTrailingInset", .horizontalTabs, tab, "Trailing padding", help: "From the x to the pill's trailing edge.", range: 0...16,
              fallback: { BrowserChromeTuning.value(.closeTrailing) }),
        // Other: the three axes every derived size follows.
        // A built-in and its copies scale Default's sizes by `densityScale`; their `level` only picks the family.
        Entry("densityScale", .other, scale, "Overall scale", help: "Scales every size the density does not set exactly, over Default's.",
              range: 0.6...1.6, step: 0.01, unit: .factor, fallback: { 1 }),
        Entry("spacing", .other, scale, "Spacing", help: "Multiplies every padding and inset that follows the grid.",
              range: DensityTokens.spacingRange, step: 0.05, unit: .factor, field: .spacing),
        Entry("fontSize", .other, scale, "Body text size", help: "Chrome's body text; titles made from it scale with it.",
              range: DensityTokens.fontSizeRange, step: 0.25, field: .fontSize),
        // Other: toolbar and omnibar.
        Entry("omnibarHeight", .other, toolbar, "Omnibar height", help: "The address bar's height.", range: 16...48),
        Entry("omnibarFontSize", .other, toolbar, "Omnibar text size", help: "The URL's text size.", range: 9...22, step: 0.25),
        Entry("omnibarCornerRadius", .other, toolbar, "Omnibar corner radius", help: "The address bar's corner.", range: 0...20),
        Entry("omnibarIconSize", .other, toolbar, "Omnibar icon size", help: "The page-info and search glyph.", range: 8...28),
        Entry("omnibarTextGap", .other, toolbar, "Omnibar icon to text", help: "From the page-info chip to the URL.", range: 0...16),
        Entry("omnibarButtonSpacing", .other, toolbar, "Toolbar button gap", help: "The gap between toolbar buttons.", range: 0...12),
        Entry("toolbarGlyphSize", .other, toolbar, "Toolbar icon size", help: "Back, forward and reload glyph boxes.", range: 8...32,
              fallback: { Metrics.toolbarGlyphSize }),
        // Other: palette.
        Entry("paletteRowHeight", .other, palette, "Row height", help: "One palette result.", range: 20...56, step: 1, fallback: metric(MetricTunables.paletteRowHeight)),
        Entry("paletteSearchHeight", .other, palette, "Search field height", help: "The palette's search field.", range: 28...72, step: 1,
              fallback: metric(MetricTunables.paletteSearchHeight)),
        Entry("paletteWidth", .other, palette, "Width", help: "The palette's width.", range: 360...1200, step: 1, fallback: metric(MetricTunables.paletteWidth)),
        // Other: chats.
        Entry("chatTextScale", .other, chat, "Agent chat text", help: "The agent chats' text, tool rows and composer, over Default's.",
              range: 0.7...1.6, step: 0.05, unit: .factor, fallback: { Typography.pageChatTextScale }),
        Entry("homeTextScale", .other, chat, "Home chat text", help: "The Home (iMessage-style) transcript's text, over Default's.",
              range: 0.7...1.6, step: 0.05, unit: .factor, fallback: { Typography.homeChatDensityScale }),
        Entry("composerZoom", .other, chat, "New Tab composer", help: "New Tab's composer size, over Default's.", range: 0.6...1.6, step: 0.05, unit: .factor,
              fallback: { 1 }),
        Entry("chatEditorMin", .other, chat, "Composer min height", help: "The chat composer's resting height.", range: 20...80, step: 1),
        // Other: window and panes.
        Entry("titlebarHeight", .other, window, "Titlebar height", help: "The unified titlebar.", range: 20...64, step: 1, fallback: metric(MetricTunables.titlebarHeight)),
        Entry("panePadding", .other, window, "Pane padding", help: "Around each pane's tab strip and content.", range: 0...16,
              fallback: { Metrics.densityPanePadding }),
        Entry("panelCornerRadius", .other, window, "Panel corner radius", help: "Floating panels: sidebar, palette.", range: 0...24,
              fallback: { Metrics.panelCornerRadius }),
        Entry("itemCornerRadius", .other, window, "Control corner radius", help: "Buttons and small controls.", range: 0...16,
              fallback: { Metrics.itemCornerRadius }),
        Entry("controlHeight", .other, window, "Control height", help: "Fields, small controls and the strip's + button.", range: 16...44,
              fallback: metric(MetricTunables.controlHeight)),
        Entry("iconSize", .other, window, "Icon size", help: "Toolbar and row icons that follow the grid.", range: 8...28, fallback: metric(MetricTunables.iconSize)),
        Entry("smallIconSize", .other, window, "Small icon size", help: "Secondary glyphs and trailing buttons.", range: 6...24,
              fallback: metric(MetricTunables.smallIconSize)),
    ]
}
