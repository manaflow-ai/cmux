import CmuxNextDesign
import CoreGraphics

/// One value the Density Lab puts on a slider: a density field or one of the density's exact tokens, with the words a
/// person reads and the value the app draws now when the token is not set.
struct DensityLabControl: Identifiable {
    enum Kind {
        /// `DensityTokens.level`.
        case level
        /// `DensityTokens.spacing`.
        case spacing
        /// `DensityTokens.fontSize` (nil follows the level).
        case fontSize
        /// `DensityTokens.tokens[name]` (nil: automatic).
        case token(String)
    }

    let id: String
    let title: String
    let help: String
    let kind: Kind
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    /// What the app draws now with the token unset: the lab draws the app in the selected density, so this is its
    /// automatic value.
    let live: @MainActor () -> Double?

    /// A group of controls under one heading.
    struct Group {
        let title: String
        let note: String?
        let controls: [DensityLabControl]
    }

    /// The groups the lab shows, top to bottom (Lawrence 2026-11-12 to 15: sidebar icons, sizing and positioning;
    /// the tab bar's gaps; roundness concentric with the window by default; toolbar icon size and spacing; one
    /// button size at every density).
    @MainActor static func groups(sidebar: [ComputedTunable]) -> [Group] { [
        Group(title: "Overall", note: nil, controls: [
            DensityLabControl(id: "level", title: "Size", help: "Tighter to roomier. Moves every row, tab and icon together.",
                              kind: .level, range: DensityTokens.levelRange, step: 0.05, unit: "", live: { nil }),
            DensityLabControl(id: "spacing", title: "Padding", help: "Multiplies the space inside rows, tabs and panels.",
                              kind: .spacing, range: DensityTokens.spacingRange, step: 0.05, unit: "×", live: { nil }),
            DensityLabControl(id: "fontSize", title: "Text size", help: "The body text of the chrome. Auto follows Size.",
                              kind: .fontSize, range: DensityTokens.fontSizeRange, step: 0.5, unit: "pt",
                              live: { Double(Metrics.tokens.levelBodySize) }),
        ]),
        Group(title: "Buttons and toolbar icons", note: "One size for every square button: sidebar toggle, Back, Forward, +, the tab bar's buttons, reload and extensions.", controls: [
            chrome(.buttonSize, "Button size", "Every square chrome button, at this density.", 14...48) { Metrics.chromeButtonSize },
            chrome(.iconInk, "Icon size", "The drawn size of back, forward, reload, extensions, the star and the top row's arrows and +.",
                   6...28) { Metrics.toolbarGlyphSize * DensityTokens.toolbarGlyphInkRatio },
            // The browser toolbar's default gap is Helium's base padding, 3 pt (`OmnibarStyle.basePadding`).
            chrome(.toolbarGap, "Gap between toolbar buttons", "Space between back, forward, reload and the extension buttons.", 0...16) { 3 },
            chrome(.topRowGap, "Gap between top row buttons", "Space between the sidebar toggle, Back and Forward.", 0...16) {
                TopRowSpacing.groupGap
            },
        ]),
        Group(title: "Tab bar", note: nil, controls: [
            chrome(.tabStripPadding, "Tab bar padding", "Space before the first tab and after the last control.", 0...24) {
                Metrics.paneChromeInset
            },
            chrome(.newTabGap, "Gap before +", "Space from the last tab to the + button.", 0...24) { Metrics.space1 },
            chrome(.spaceAfterPlus, "Space between + and ⋮", "The room after the + before the tab bar's buttons at its end.", 0...32) {
                Metrics.paneChromeInset
            },
            chrome(.tabButtonGap, "Gap between ⋮ and pins", "Space between the buttons at the end of the tab bar (pins, Exit Zoom, ⋮).", 0...16) {
                Metrics.space1 / 2
            },
            chrome(.tabTrailing, "⋮ distance from edge", "How far the last button sits from the pane's right edge.", 0...24) {
                max(0, Metrics.paneTrailingControlCenter - TitlebarBandButton.side / 2)
            },
        ] + BrowserChromeMetric.allCases.map(browser)),
        Group(title: "Roundness", note: "Auto is concentric with the macOS window corner.", controls: [
            chrome(.cardRadius, "Content card", "The corner of the main content card.", 0...32) {
                Metrics.mainPaneCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius)
            },
            chrome(.tabRadius, "Tabs, omnibar, buttons and rows", "One radius for all of them; auto nests inside the content card.", 0...20) {
                Metrics.tabCornerRadius
            },
            metric(MetricTunables.densityPaneCornerRadius, "Panes", 0...24),
        ]),
        Group(title: "Sidebar rows and icons", note: "The Sidebar Row Tuner's values, kept per density.",
              controls: sidebar.map(sidebarControl)),
        Group(title: "Sizes", note: nil, controls: [
            metric(MetricTunables.titlebarHeight, "Titlebar height", 24...72),
            metric(MetricTunables.tabStripHeight, "Tab bar height", 20...64),
            metric(MetricTunables.iconSize, "Tab and row icons", 10...32),
            metric(MetricTunables.smallIconSize, "Small icons", 8...28),
            metric(MetricTunables.paletteRowHeight, "Palette row height", 20...60),
        ]),
    ] }

    private static func chrome(_ token: ChromeLabToken, _ title: String, _ help: String, _ range: ClosedRange<Double>,
                               live: @escaping @MainActor () -> CGFloat?) -> DensityLabControl {
        DensityLabControl(id: token.rawValue, title: title, help: help, kind: .token(token.rawValue), range: range, step: 0.5,
                          unit: "pt", live: { live().map(Double.init) })
    }

    private static func browser(_ metric: BrowserChromeMetric) -> DensityLabControl {
        DensityLabControl(id: BrowserChromeTuning.densityKey(metric), title: metric.label, help: metric.help,
                          kind: .token(BrowserChromeTuning.densityKey(metric)), range: metric.range, step: 0.5,
                          unit: metric == .closeHoverOpacity ? "%" : "pt", live: { Double(BrowserChromeTuning.value(metric)) })
    }

    /// A Sidebar Row Tuner number: its key is the density token's, so a density's token is that row value there.
    private static func sidebarControl(_ tunable: ComputedTunable) -> DensityLabControl {
        let descriptor = tunable.descriptor
        var range: ClosedRange<Double> = 0...40, step = 0.5
        if case .number(let r, let s, _) = descriptor.kind { range = r; step = s }
        return DensityLabControl(id: descriptor.key, title: descriptor.label, help: descriptor.help, kind: .token(descriptor.key),
                                 range: range, step: step, unit: "pt", live: { Double(tunable.value) })
    }

    private static func metric(_ tunable: MetricTunable, _ title: String, _ range: ClosedRange<Double>) -> DensityLabControl {
        DensityLabControl(id: tunable.name, title: title, help: tunable.descriptor.help, kind: .token(tunable.name), range: range,
                          step: 1, unit: "pt", live: { Double(tunable.value) })
    }

    /// The value `density` sets for this control, nil when it is automatic.
    func explicitValue(in density: DensityTokens) -> Double? {
        switch kind {
        case .level: density.level
        case .spacing: density.spacing
        case .fontSize: density.fontSize
        case .token(let name): density.tokens[name]
        }
    }

    /// `density` with this control set to `value` (nil: automatic; Size and Padding go back to 0 and 1).
    func applying(_ value: Double?, to density: DensityTokens) -> DensityTokens {
        var result = density
        switch kind {
        case .level: result.level = value ?? 0
        case .spacing: result.spacing = value ?? 1
        case .fontSize: result.fontSize = value
        case .token(let name): result.tokens[name] = value
        }
        return result
    }

    /// Whether the control can go back to automatic.
    var canBeAutomatic: Bool {
        switch kind {
        case .level, .spacing: false
        case .fontSize, .token: true
        }
    }
}
