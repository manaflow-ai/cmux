import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CoreText
@testable import CmuxNextSidebar
import Testing

/// Issue 28793: the sidebar's defaults (compact app density, `sidebar.density` normal, `sidebar.textSize`
/// small) match the Codex desktop sidebar (2026-11-02: "the default for the sidebar text should be the codex
/// text size"): 13 pt row titles at weight 430, 12 pt detail
/// lines (in the macOS system font, the UI font since 2026-11-07), one-line rows on a 30 pt pitch (row plus row gap) and 8 pt horizontal padding. Only the
/// sidebar's own defaults move; other chrome keeps `Typography.body` and `Metrics.sidebarRowHeight`,
/// and a person's Interface Size, chrome font size, `appearance.metrics.sidebarRowHeight`, sidebar
/// density and custom densities still win. `sidebar.density` compact keeps the sidebar from before, exactly,
/// for whoever picked it; comfortable is roomier than Normal; the person's own sizes (`sidebar.titleSize`,
/// `sidebar.detailSize`, `sidebar.rowHeight`, `sidebar.rowPadding`) win over all of them.
@MainActor @Suite(.serialized) struct SidebarCodexTextDefaultsTests {
    private static let first = WorkspaceID("ws-codex-1")
    private static let second = WorkspaceID("ws-codex-2")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: first, title: "workspace-1", kind: .terminal)),
                .workspace(SidebarWorkspace(id: second, title: "workspace-2", kind: .terminal)),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections = DesignSettings.shared.sidebarSections
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.updateBands()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// Runs `body` at app density `tokens`, sidebar density `density` and sidebar text size `textSize` with
    /// `override` as `appearance.metrics.sidebarRowHeight` and `fontSize` as the chrome font size, then restores them.
    private static func at(_ tokens: DensityTokens = DensityPreset.compact.tokens, sidebar density: SidebarDensity = .normal,
                           textSize: SidebarTextSize = .small, rowHeight override: CGFloat? = nil, fontSize: CGFloat? = nil,
                           _ body: () throws -> Void) rethrows {
        let shared = DesignSettings.shared
        let saved = (shared.sidebarSections, shared.overrides[.sidebarRowHeight], shared.overrides[.chromeFontSize])
        shared.sidebarSections.density = density
        shared.sidebarSections.textSize = textSize
        shared.setOverride(.sidebarRowHeight, override)
        shared.setOverride(.chromeFontSize, fontSize)
        defer {
            shared.sidebarSections = saved.0
            shared.setOverride(.sidebarRowHeight, saved.1)
            shared.setOverride(.chromeFontSize, saved.2)
        }
        try DensityTokens.$scoped.withValue(tokens, operation: body)
    }

    /// The CSS weight the font's `wght` axis draws `font` at, nil for a font set at a named weight.
    private static func drawnWeight(_ font: NSFont) -> Double? {
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: UInt32(0x7767_6874))]?.doubleValue
    }

    // MARK: Defaults

    @Test func titlesAre13PointAtCodexWeightAndDetailLinesAre12() throws {
        try Self.at {
            #expect(SidebarStyle.titleFont.pointSize == 13)
            #expect(SidebarStyle.subtitleFont.pointSize == 12)
            // The Codex sidebar's 430: 30% of the way from regular to medium, in the macOS system font
            // (the UI font since 2026-11-07), whose weight axis draws between the two.
            let expected = NSFont.Weight.regular.rawValue + (NSFont.Weight.medium.rawValue - NSFont.Weight.regular.rawValue) * 0.3
            #expect(abs(TypeScale.sidebar.rawValue - expected) < 0.0001, "TypeScale.sidebar is \(TypeScale.sidebar.rawValue)")
            #expect(SidebarStyle.titleFont.familyName == NSFont.systemFont(ofSize: 13).familyName, "the system UI font")
            // The system font draws only its named faces from a weight (430 drew as medium), so the title
            // sets the font's `wght` axis to 430 (CheckedFont.between).
            let drawn = try #require(Self.drawnWeight(SidebarStyle.titleFont), "the title sets the wght axis")
            #expect(abs(drawn - 430) < 1, "row titles draw at wght \(drawn)")
            // A realized workspace row draws its title in that font.
            let row = try #require(Self.sidebar().list.rowViews[.workspace(Self.first)] as? WorkspaceRowView)
            #expect(row.title.font.pointSize == 13)
        }
    }

    @Test func oneLineRowsSitOnA30PointPitchWith8PointPadding() throws {
        try Self.at {
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 28 && metrics.rowSpacing == 2, "row \(metrics.rowHeight), gap \(metrics.rowSpacing)")
            #expect(SidebarStyle.horizontalInset == 8)
            #expect(SidebarRegionMetrics.standard.rowHeight == 28, "pinned and band rows take the list's row")
            let sidebar = Self.sidebar()
            let a = sidebar.list.frame(for: try #require(sidebar.list.displayed.row(for: .workspace(Self.first))))
            let b = sidebar.list.frame(for: try #require(sidebar.list.displayed.row(for: .workspace(Self.second))))
            #expect(abs(abs(b.minY - a.minY) - 30) < 0.5, "workspace rows step \(abs(b.minY - a.minY)) pt")
            let row = try #require(sidebar.list.rowViews[.workspace(Self.first)] as? WorkspaceRowView)
            #expect(row.title.frame.minX == SidebarStyle.horizontalInset, "a title without an icon starts at the 8 pt inset")
        }
    }

    @Test func theDefaultsAreNormalDensityAndSmallText() {
        #expect(SidebarSectionsPreferences.defaults.density == .normal)
        #expect(SidebarSectionsPreferences.defaults.textSize == .small)
        #expect(SidebarSectionsPreferences.defaults.titleSize == nil && SidebarSectionsPreferences.defaults.rowHeight == nil)
    }

    @Test func otherChromeKeepsItsSizes() {
        Self.at {
            #expect(Typography.body.pointSize == 12 && Typography.caption.pointSize == 10.5)
            #expect(Metrics.sidebarRowHeight == 24, "Settings, Home and titlebar rows keep the app's row metric")
        }
    }

    // MARK: Overrides

    @Test func theRowHeightOverrideStillSetsSidebarRows() {
        Self.at(rowHeight: 22) {
            #expect(SidebarLayoutMetrics.standard.rowHeight == 22)
            #expect(SidebarRegionMetrics.standard.rowHeight == 22)
        }
    }

    @Test func aCustomDensityRowTokenStillSetsSidebarRows() {
        let tight = DensityTokens(id: "tight", name: "Tight", level: 0, tokens: ["sidebarRowHeight": 22])
        Self.at(tight) { #expect(SidebarLayoutMetrics.standard.rowHeight == 22) }
    }

    @Test func theChromeFontSizeScalesSidebarText() {
        Self.at(fontSize: 14) {
            #expect(abs(SidebarStyle.titleFont.pointSize - 13 * 14 / 12) < 0.01, "title \(SidebarStyle.titleFont.pointSize)")
            #expect(abs(SidebarStyle.subtitleFont.pointSize - 14) < 0.01, "detail \(SidebarStyle.subtitleFont.pointSize)")
        }
    }

    @Test func theComfortableAppDensityStaysLarger() {
        // The comfortable app density scales the Codex sizes like every other style (its tokens changed
        // upstream, so read them rather than pin numbers): larger than at compact, from the same styles.
        Self.at(DensityPreset.comfortable.tokens) {
            #expect(SidebarStyle.titleFont.pointSize == Typography.sidebarRow.pointSize && SidebarStyle.titleFont.pointSize > 13)
            #expect(SidebarStyle.subtitleFont.pointSize == Typography.sidebarDetail.pointSize && SidebarStyle.subtitleFont.pointSize > 12)
            #expect(SidebarLayoutMetrics.standard.rowHeight == Metrics.sidebarListRowHeight)
            #expect(SidebarLayoutMetrics.standard.rowHeight > 28)
        }
    }

    /// Compact is the sidebar from before Normal, number for number, so a person who picked it sees no change.
    @Test func compactKeepsTheSidebarFromBefore() throws {
        try Self.at(sidebar: .compact) {
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 24 && metrics.rowHeight + metrics.rowSpacing == 26)
            #expect(SidebarStyle.horizontalInset == 6)
            #expect(SidebarStyle.titleFont == Typography.body, "the app's body font, regular")
            #expect(SidebarStyle.subtitleFont == Typography.caption)
            #expect(metrics.minimal.rowHeight == 20, "Minimal Mode's rows too")
            let sidebar = Self.sidebar()
            let a = sidebar.list.frame(for: try #require(sidebar.list.displayed.row(for: .workspace(Self.first))))
            let b = sidebar.list.frame(for: try #require(sidebar.list.displayed.row(for: .workspace(Self.second))))
            #expect(abs(abs(b.minY - a.minY) - 26) < 0.5, "workspace rows step \(abs(b.minY - a.minY)) pt")
        }
        // Compact with the first setting's Larger (now Medium) keeps its 14 pt text on 29 pt rows.
        Self.at(sidebar: .compact, textSize: .medium) {
            #expect(SidebarStyle.titleFont.pointSize == 14 && SidebarLayoutMetrics.standard.rowHeight == 29)
        }
        try Self.at(DensityPreset.comfortable.tokens, sidebar: .compact) {
            #expect(SidebarLayoutMetrics.standard.rowHeight == Metrics.sidebarRowHeight && SidebarStyle.titleFont == Typography.body,
                    "compact at the comfortable app density is that density's row and body, as before")
        }
    }

    @Test func comfortableIsRoomierThanNormalAndExpandedTakesNormalsLines() {
        Self.at(sidebar: .comfortable) {
            #expect(SidebarLayoutMetrics.standard.rowHeight == 32, "comfortable row")
            #expect(SidebarStyle.horizontalInset == 8, "the grid's comfortable inset")
            #expect(SidebarStyle.titleFont.pointSize == 13, "Normal's text, on more room")
        }
        Self.at(sidebar: .expanded) {
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 28 && SidebarStyle.horizontalInset == 8, "expanded keeps Normal's one-line tokens")
            #expect(metrics.expanded.groupHeaderHeight > metrics.rowHeight, "and draws two-line rows")
        }
    }

    /// The person's own sizes win over the density and the text size, and Interface Size still scales them.
    @Test func customSizesWin() throws {
        let shared = DesignSettings.shared
        for density in [SidebarDensity.compact, .normal, .comfortable] {
            try Self.at(sidebar: density, textSize: .large) {
                let saved = shared.sidebarSections
                defer { shared.sidebarSections = saved }
                shared.sidebarSections.titleSize = 15
                shared.sidebarSections.detailSize = 11
                shared.sidebarSections.rowHeight = 34
                shared.sidebarSections.rowPadding = 12
                #expect(SidebarStyle.titleFont.pointSize == 15 && SidebarStyle.subtitleFont.pointSize == 11, "\(density) text")
                #expect(SidebarLayoutMetrics.standard.rowHeight == 34 && SidebarStyle.horizontalInset == 12, "\(density) rows")
                let row = try #require(Self.sidebar().list.rowViews[.workspace(Self.first)] as? WorkspaceRowView)
                #expect(row.title.font.pointSize == 15 && row.title.frame.minX == 12, "\(density): a realized row")
            }
        }
        Self.at(fontSize: 14) {
            let saved = shared.sidebarSections
            defer { shared.sidebarSections = saved }
            shared.sidebarSections.titleSize = 15
            #expect(abs(SidebarStyle.titleFont.pointSize - 15 * 14 / 12) < 0.01, "Interface Size scales a custom size")
        }
    }

    /// The Debug override of the app's one-line row (`metrics.sidebarRowHeight`) sizes only the chrome that
    /// reads it: it neither moves the sidebar list's rows nor makes a detail row shorter than a one-line row.
    @Test func theAppRowDebugOverrideLeavesSidebarRows() {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(MetricTunables.metrics.map(\.descriptor))
        store.register(SidebarTunables.all)
        let rowKey = MetricTunables.sidebarRowHeight.tunable.key
        let saved = store.override(rowKey)
        store.set(rowKey, .number(40))
        defer {
            store.set(rowKey, saved)
            SidebarTunablesWatch.shared.changed()
        }
        Self.at {
            #expect(Metrics.sidebarRowHeight == 40)
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 28 && metrics.rowHeightWithSubtitle == 28 + SidebarStyle.detailLineHeight,
                    "row \(metrics.rowHeight), with detail \(metrics.rowHeightWithSubtitle)")
        }
    }
}
