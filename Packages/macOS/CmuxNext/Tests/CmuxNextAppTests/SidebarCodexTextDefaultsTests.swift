import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CoreText
import Testing

/// Issue 28793: the sidebar list's base tokens (compact app density, `sidebar.density` compact,
/// `sidebar.textSize` small) match the Codex desktop sidebar: 13 pt row titles at weight 430, 12 pt detail
/// lines, one-line rows on a 30 pt pitch (row plus row gap) and 8 pt horizontal padding. Only the
/// sidebar's own defaults move; other chrome keeps `Typography.body` and `Metrics.sidebarRowHeight`,
/// and a person's Interface Size, chrome font size, `appearance.metrics.sidebarRowHeight`, sidebar
/// density and custom densities still win. The default text size is Medium, the ChatGPT size a step
/// above (2026-10-30: "default is ChatGPT size. the one that is current is small"; `SidebarTextSizeTests`).
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
    private static func at(_ tokens: DensityTokens = DensityPreset.compact.tokens, sidebar density: SidebarDensity = .compact,
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

    /// The CSS weight Inter's `wght` axis draws `font` at, nil for a face without the axis.
    private static func drawnWeight(_ font: NSFont) -> Double? {
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: UInt32(0x7767_6874))]?.doubleValue
    }

    // MARK: Defaults

    @Test func titlesAre13PointAtCodexWeightAndDetailLinesAre12() throws {
        try Self.at {
            #expect(SidebarStyle.titleFont.pointSize == 13)
            #expect(SidebarStyle.subtitleFont.pointSize == 12)
            #expect(SidebarStyle.tabTitleFont.pointSize == 12 && SidebarStyle.tabDetailFont.pointSize == 12)
            #expect(abs(BundledFonts.cssWeight(TypeScale.sidebar) - 430) < 0.5, "TypeScale.sidebar is \(BundledFonts.cssWeight(TypeScale.sidebar))")
            if BundledFonts.isRegistered {
                #expect(SidebarStyle.titleFont.familyName == TypeScale.fileFamily, "the sidebar keeps Inter")
                let weight = try #require(Self.drawnWeight(SidebarStyle.titleFont), "Inter's wght axis")
                #expect(abs(weight - 430) < 1, "row titles draw at wght \(weight)")
            }
            // A realized workspace row draws its title in that font.
            let row = try #require(Self.sidebar().list.rowViews[.workspace(Self.first)] as? WorkspaceRowView)
            #expect(row.title.font?.pointSize == 13)
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

    @Test func theDefaultTextSizeIsMediumAStepAboveCodex() {
        #expect(SidebarSectionsPreferences.defaults.textSize == .medium)
        Self.at(textSize: .medium) {
            #expect(SidebarStyle.titleFont.pointSize == 14 && SidebarStyle.subtitleFont.pointSize == 13)
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight + metrics.rowSpacing == 31, "ChatGPT's 31 pt pitch")
            #expect(SidebarStyle.horizontalInset == 8, "the inset is the density's, not the text size's")
        }
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
        Self.at(DensityPreset.comfortable.tokens) {
            #expect(SidebarStyle.titleFont.pointSize == 14 && SidebarStyle.subtitleFont.pointSize == 13)
            #expect(SidebarLayoutMetrics.standard.rowHeight == 32)
        }
    }

    @Test func comfortableAndExpandedSidebarDensitiesStayLargerThanCompact() {
        Self.at(sidebar: .comfortable) {
            #expect(SidebarLayoutMetrics.standard.rowHeight == 32, "comfortable row")
            #expect(SidebarStyle.horizontalInset == 10, "comfortable inset")
            #expect(SidebarStyle.titleFont.pointSize == 13, "density keeps the text size")
        }
        Self.at(sidebar: .expanded) {
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 28 && SidebarStyle.horizontalInset == 8, "expanded keeps compact's one-line tokens")
            #expect(metrics.expanded.groupHeaderHeight > metrics.rowHeight, "and draws two-line rows")
        }
    }

    /// The Debug override of the app's one-line row (`metrics.sidebarRowHeight`) sizes only the chrome that
    /// reads it: it neither moves the sidebar list's rows nor makes a detail row shorter than a one-line row.
    @Test func theAppRowDebugOverrideLeavesSidebarRows() {
        let store = TunableStore.shared
        let saved = (store.override(MetricTunables.sidebarRowHeight.key), store.override(SidebarTunables.evenRowText.key))
        store.set(MetricTunables.sidebarRowHeight.key, .number(40))
        store.set(SidebarTunables.evenRowText.key, .bool(false))
        defer {
            store.set(MetricTunables.sidebarRowHeight.key, saved.0)
            store.set(SidebarTunables.evenRowText.key, saved.1)
        }
        Self.at {
            #expect(Metrics.sidebarRowHeight == 40)
            let metrics = SidebarLayoutMetrics.standard
            #expect(metrics.rowHeight == 28 && metrics.rowHeightWithSubtitle == 28 + 12,
                    "row \(metrics.rowHeight), with detail \(metrics.rowHeightWithSubtitle)")
        }
    }
}
