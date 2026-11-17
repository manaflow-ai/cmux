import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSettingsWindow
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Testing

/// The Density Playground (Lawrence 2026-11-17: "make a density playground cmd shift p thing so i can fine tune every
/// aspect of density, in terms of vertical and horizontal tabs, and also create new densities").
///
/// Every value it lists must reach what chrome draws (vertical tabs: the sidebar's rows and a pane's vertical tab
/// list; horizontal tabs: the strip; the rest), a custom density must survive a restart and apply, and the built-ins
/// must never change.
@MainActor @Suite(.serialized)
struct DensityPlaygroundTests {
    // MARK: Every value reaches its view

    /// What each value sizes, read where the view reads it, as text (a number, or the page script for the
    /// composer values). A value with no probe here fails `everyEntryHasAProbe`.
    static let probes: [String: @MainActor () -> String] = [
        "sidebarRowHeight": { "\(SidebarDensityTokens.rowHeight)" },
        "sidebarRowGap": { "\(SidebarDensityTokens.rowSpacing)" },
        "sidebarRowInset": { "\(SidebarDensityTokens.horizontalInset)" },
        "sidebarContentInset": { "\(SidebarDensityTokens.contentInset)" },
        "sidebarCornerRadius": { "\(SidebarDensityTokens.rowCornerRadius)" },
        "sidebarIconColumn": { "\(SidebarStyle.iconBox)" },
        "sidebarGlyphInk": { "\(SidebarRowTuning.glyphSize.value)" },
        "sidebarIconGap": { "\(SidebarRowTuning.glyphGap.value)" },
        "sidebarTitleSize": { "\(SidebarStyle.titleFont.pointSize)" },
        "sidebarGroupIndent": { "\(SidebarStyle.groupOffset(depth: 2))" },
        "sidebarHeaderHeight": { "\(SidebarDensityTokens.headerHeight)" },
        "sidebarHeadingSize": { "\(SidebarStyle.headerFont.pointSize)" },
        "sidebarSectionGap": { "\(SidebarDensityTokens.sectionSpacing)" },
        "sidebarBandGap": { "\(SidebarRowTuning.bandGap.value)" },
        "sidebarStatusDot": { "\(SidebarRowTuning.statusDot.value)" },
        "sidebarWidth": { "\(Metrics.sidebarWidth)" },
        "verticalTabRowHeight": { "\(VerticalTabListMetrics.current.rowHeight)" },
        "verticalTabRowGap": { "\(VerticalTabListMetrics.current.rowSpacing)" },
        "verticalTabPadding": { "\(VerticalTabListMetrics.current.padding)" },
        "verticalTabIconSize": { "\(VerticalTabListMetrics.current.iconSize)" },
        "verticalTabHeaderHeight": { "\(VerticalTabListMetrics.current.headerHeight)" },
        "verticalTabIndent": { "\(VerticalTabListMetrics.current.groupIndent)" },
        "verticalTabCornerRadius": { "\(VerticalTabListMetrics.current.cornerRadius)" },
        "verticalTabTileSize": { "\(VerticalTabListMetrics.current.tileSize)" },
        "verticalTabWidth": { "\(VerticalTabTunables.expandedWidth.value)" },
        "browserRowHeight": { "\(TabStripMetrics().tabHeight)" },
        "browserRowGap": { "\(TabStripMetrics().stripHeight)" },
        "tabStripEndGap": { "\(TabStripMetrics().stripHorizontalPadding)" },
        "tabGap": { "\(TabStripMetrics().tabBackgroundInset)" },
        "tabMinActiveWidth": { "\(TabStripMetrics().minActiveTabWidth)" },
        "tabMinInactiveWidth": { "\(TabStripMetrics().minInactiveTabWidth)" },
        "tabMaxWidth": { "\(TabStripMetrics().maxTabWidth)" },
        "tabPinnedWidth": { "\(TabStripMetrics().pinnedTabWidth)" },
        "tabCornerRadius": { "\(TabStripMetrics().cornerRadius)" },
        "tabIconLeading": { "\(TabStripMetrics().contentLeadingInset)" },
        "tabIconSize": { "\(TabStripMetrics().iconSize)" },
        "tabIconTitleGap": { "\(TabStripMetrics().iconTitleSpacing)" },
        "tabTitleSize": { "\(Typography.tabTitle.pointSize)" },
        "tabTitleDrop": { "\(Metrics.densityToken("tabTitleDrop") ?? 0)" },
        "tabCloseSize": { "\(TabStripMetrics().closeButtonSize)" },
        "tabCloseGlyphSize": { "\(TabStripMetrics().closeGlyphSize)" },
        "tabCloseCornerRadius": { "\(TabStripMetrics().closeCornerRadius)" },
        "tabTrailingInset": { "\(TabStripMetrics().contentTrailingInset)" },
        "densityScale": { "\(Metrics.scrollEdgeFade) \(Metrics.paletteSearchHeight)" },
        "spacing": { "\(Metrics.space3)" },
        "fontSize": { "\(Typography.body.pointSize)" },
        "omnibarHeight": { "\(OmnibarMetrics.current.barHeight)" },
        "omnibarFontSize": { "\(OmnibarMetrics.current.fontSize)" },
        "omnibarCornerRadius": { "\(OmnibarStyle.barCornerRadius)" },
        "omnibarIconSize": { "\(OmnibarStyle.iconSide)" },
        "omnibarTextGap": { "\(OmnibarStyle.textLeading)" },
        "omnibarButtonSpacing": { "\(OmnibarStyle.buttonSpacing)" },
        "toolbarGlyphSize": { "\(Metrics.toolbarGlyphSize)" },
        "paletteRowHeight": { "\(Metrics.paletteRowHeight)" },
        "paletteSearchHeight": { "\(Metrics.paletteSearchHeight)" },
        "paletteWidth": { "\(Metrics.paletteWidth)" },
        "chatTextScale": { "\(Typography.pageChatTextScale)" },
        "homeTextScale": { "\(HomeNativeTranscriptView.chatScale)" },
        "composerZoom": { DesignSettings.shared.interfaceScaleScript() },
        "chatEditorMin": { DesignSettings.shared.interfaceScaleScript() },
        "titlebarHeight": { "\(Metrics.titlebarHeight)" },
        "panePadding": { "\(Metrics.densityPanePadding)" },
        "panelCornerRadius": { "\(Metrics.panelCornerRadius)" },
        "itemCornerRadius": { "\(Metrics.itemCornerRadius)" },
        "controlHeight": { "\(Metrics.controlHeight)" },
        "iconSize": { "\(Metrics.iconSize)" },
        "smallIconSize": { "\(Metrics.smallIconSize)" },
    ]

    static var entries: [DensityTokenCatalog.Entry] {
        DensityTokenCatalog.entries(fallbacks: [SidebarRowTuning.densityFallbacks, VerticalTabListMetrics.densityFallbacks, OmnibarMetrics.densityFallbacks])
    }

    @Test func everyEntryHasAProbe() {
        let missing = Self.entries.map(\.key).filter { Self.probes[$0] == nil }
        #expect(missing.isEmpty, "no probe for \(missing)")
    }

    /// A value moved a few steps changes what chrome draws, on Default and on Compact copies.
    @Test(arguments: [DensityPreset.cozy, .compact])
    func everyEntryReachesWhatChromeDraws(preset: DensityPreset) {
        let base = CustomDensitiesSetting.duplicate(preset.tokens, name: "Probe", existing: [])
        var dead: [String] = []
        for entry in Self.entries {
            guard let probe = Self.probes[entry.key] else { continue }
            let current = DensityPlaygroundModel.value(entry, in: base) ?? entry.range.lowerBound
            let delta = entry.unit == .factor ? 0.2 : max(4, entry.step * 8)
            let moved = current + delta <= entry.range.upperBound ? current + delta : current - delta
            let before = DensityTokens.$scoped.withValue(base) { probe() }
            // A nudge first; a value with a floor (the selected tab's minimum never drops under its icon and close
            // button) must still move what is drawn somewhere in its range.
            let reaches = [moved, entry.range.upperBound, entry.range.lowerBound].contains { value in
                DensityTokens.$scoped.withValue(DensityTokenCatalog.setting(entry, to: value, in: base)) { probe() } != before
            }
            if !reaches { dead.append("\(entry.key) (\(current) → \(moved): \(before))") }
        }
        #expect(dead.isEmpty, "\(preset): values that change nothing on screen: \(dead)")
    }

    /// A slider starts where chrome is: an unset value reads what is drawn, so the first move does not jump.
    @Test func everyEntryHasAValueAtEveryBuiltIn() {
        for preset in DensityPreset.allCases {
            let missing = Self.entries.filter { DensityPlaygroundModel.value($0, in: preset.tokens) == nil }.map(\.key)
            #expect(missing.isEmpty, "\(preset): no value for \(missing)")
        }
    }

    /// Vertical tabs, laid out for real: a sidebar row and a pane's vertical tab row take the density's heights.
    @Test func aCustomDensitySizesBothVerticalTabLists() throws {
        var mine = CustomDensitiesSetting.duplicate(DensityPreset.cozy.tokens, name: "Tall Rows", existing: [])
        mine = DensityTokenCatalog.setting(try #require(DensityTokenCatalog.entry("sidebarRowHeight")), to: 40, in: mine)
        mine = DensityTokenCatalog.setting(try #require(DensityTokenCatalog.entry("verticalTabRowHeight")), to: 44, in: mine)
        mine = DensityTokenCatalog.setting(try #require(DensityTokenCatalog.entry("sidebarRowGap")), to: 6, in: mine)
        try DensityTokens.$scoped.withValue(mine) {
            let sidebar = Self.sidebar()
            let row = try #require(sidebar.list.rowViews.values.first)
            #expect(row.frame.height >= 40, "a sidebar row is \(row.frame.height) pt")
            #expect(SidebarDensityTokens.rowSpacing == 6)
            let list = VerticalTabListMetrics.current
            #expect(list.rowHeight == 44)
        }
        let defaultRow = DensityTokens.$scoped.withValue(DensityPreset.cozy.tokens) { Self.sidebar().list.rowViews.values.first?.frame.height }
        #expect(defaultRow.map { $0 < 40 } == true, "Default's row stays its own: \(String(describing: defaultRow))")
    }

    /// Horizontal tabs: the strip's pill, gaps and close button follow a custom density.
    @Test func aCustomDensitySizesTheHorizontalStrip() throws {
        var mine = CustomDensitiesSetting.duplicate(DensityPreset.cozy.tokens, name: "Roomy Strip", existing: [])
        for (key, value) in [("browserRowHeight", 34.0), ("browserRowGap", 6), ("tabCloseSize", 18), ("tabMaxWidth", 260), ("tabStripEndGap", 10)] {
            mine = DensityTokenCatalog.setting(try #require(DensityTokenCatalog.entry(key)), to: value, in: mine)
        }
        DensityTokens.$scoped.withValue(mine) {
            let strip = TabStripMetrics()
            #expect(strip.tabHeight >= 34)
            #expect(strip.stripHeight >= strip.tabHeight + 2 * 6 - Metrics.stripTopOutset)
            #expect(strip.closeButtonSize == 18)
            #expect(strip.maxTabWidth == 260)
            #expect(strip.stripHorizontalPadding == 10)
        }
    }

    // MARK: Built-ins

    /// The keys the playground added are unset in every built-in, so a built-in draws exactly as before.
    @Test func builtInsDoNotSetThePlaygroundsNewKeys() {
        let added = ["sidebarRowGap", "sidebarCornerRadius", "sidebarGroupIndent", "sidebarHeadingSize", "sidebarSectionGap", "sidebarBandGap",
                     "sidebarStatusDot", "verticalTabRowHeight", "verticalTabRowGap", "verticalTabPadding", "verticalTabIconSize",
                     "verticalTabHeaderHeight", "verticalTabIndent", "verticalTabCornerRadius", "verticalTabTileSize", "verticalTabWidth",
                     "tabStripEndGap", "tabCloseSize", "tabCloseGlyphSize", "tabCloseCornerRadius", "tabTrailingInset", "chatTextScale",
                     "homeTextScale"]
        for preset in DensityPreset.allCases {
            let set = added.filter { preset.tokens.tokens[$0] != nil }
            #expect(set.isEmpty, "\(preset) sets \(set)")
        }
    }

    /// Editing a built-in makes a copy and edits that; the built-in and its id stay as they were.
    @Test func editingABuiltInMakesACopy() async throws {
        let f = Self.fixture(active: DensityPreset.compact.tokens)
        let gap = try #require(DensityTokenCatalog.entry("sidebarRowGap"))
        f.model.set(gap, to: 5)
        #expect(!f.model.draft.isBuiltIn)
        #expect(f.model.draft.basedOn == "compact")
        #expect(f.model.draft.name == "Compact Custom")
        #expect(f.model.draft.tokens["sidebarRowGap"] == 5)
        #expect(DensityPreset.compact.tokens.tokens["sidebarRowGap"] == nil)
        #expect(Array(f.model.densities.prefix(DensityPreset.allCases.count)) == DensityPreset.allCases.map(\.tokens))
        f.model.set(gap, to: 6)
        #expect(f.model.customs.count == 1, "a second edit edits the same copy")
        #expect(f.model.isChanged(gap) && f.model.changedCount == 1)
        f.model.reset(gap)
        #expect(!f.model.isChanged(gap) && f.model.changedCount == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.design.densityTokens == f.model.draft, "edits draw live")
    }

    // MARK: Saving, restart, import

    /// A saved custom density is in cmux.json: read back as a restart reads it, it is listed and in use.
    @Test func aCustomDensityPersistsAndApplies() throws {
        let f = Self.fixture(active: DensityPreset.cozy.tokens)
        f.model.duplicate(name: "My Tabs")
        f.model.set(try #require(DensityTokenCatalog.entry("verticalTabRowHeight")), to: 26)
        f.model.set(try #require(DensityTokenCatalog.entry("browserRowHeight")), to: 26)
        f.model.flush()
        let saved = try #require(f.saves.last)
        let root: JSONValue = .object(["appearance": .object([
            "customDensities": .array(saved.customs.map(CustomDensitiesSetting.json)), "customDensity": .string(saved.active.id),
        ])])
        let restarted = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics)
        #expect(restarted.customDensities == f.model.customs)
        #expect(restarted.selectedDensity == f.model.draft)
        #expect(restarted.selectedDensity.name == "My Tabs")
        #expect(restarted.selectedDensity.tokens["verticalTabRowHeight"] == 26)
        #expect(restarted.diagnostics.filter { $0.path.hasPrefix("appearance.customDensit") }.isEmpty, "\(restarted.diagnostics)")
    }

    @Test func renameAndDeleteKeepTheListRight() {
        let f = Self.fixture(active: DensityPreset.spacious.tokens)
        let made = f.model.duplicate()
        #expect(made.name == "Spacious Custom")
        f.model.rename("Big Screen")
        #expect(f.model.draft.name == "Big Screen" && f.model.draft.id == made.id)
        #expect(f.model.customs.map(\.name) == ["Big Screen"])
        f.model.deleteDraft()
        #expect(f.model.customs.isEmpty)
        #expect(f.model.draft == DensityPreset.spacious.tokens, "deleting goes back to the built-in it came from")
        #expect(f.saves.last?.customs.isEmpty == true)
    }

    /// Tabbing through the name field of a built-in (it shows the display name) makes no copy.
    @Test func leavingABuiltInsNameAsShownMakesNoCopy() {
        let f = Self.fixture(active: DensityPreset.cozy.tokens)
        f.model.rename(f.model.name(f.model.draft))
        #expect(f.model.customs.isEmpty && f.model.isBuiltIn)
        #expect(f.saves.isEmpty)
    }

    /// Export writes what Import (and the Settings density card) reads; importing again adds a copy, never a replacement.
    @Test func exportedJSONImportsAsANewDensity() throws {
        let f = Self.fixture(active: DensityPreset.cozy.tokens)
        f.model.duplicate(name: "Shared")
        f.model.set(try #require(DensityTokenCatalog.entry("tabGap")), to: 8)
        let json = f.model.exportJSON
        #expect(f.model.importJSON(json) == 1)
        #expect(f.model.customs.count == 2)
        #expect(f.model.draft.name == "Shared 2" && f.model.draft.id != f.model.customs[0].id)
        #expect(f.model.draft.tokens == f.model.customs[0].tokens)
        #expect(f.model.importJSON("not json") == 0 && f.model.notice != nil)
        #expect(f.model.exportSwift.contains("\"tabGap\": 8,"))
    }

    // MARK: Palette

    @Test func thePaletteListsTheDensityPlayground() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let provider = try #require(services.palette.sources.extraProviders.first { $0.id == "densities" })
        let items = await provider.items()
        let row = try #require(items.first { $0.id == "density:playground" })
        #expect(row.title == "Density Playground")
        #expect(row.keywords.contains("density") && row.keywords.contains("tabs"))
    }

    // MARK: Cost of a live change

    /// One slider tick applies one density: a sidebar laid out again after it stays well inside a frame.
    @Test func aLiveChangeIsCheap() throws {
        let sidebar = Self.sidebar()
        var mine = CustomDensitiesSetting.duplicate(DensityPreset.cozy.tokens, name: "Tick", existing: [])
        let gap = try #require(DensityTokenCatalog.entry("sidebarRowGap"))
        let saved = DesignSettings.shared.densityTokens
        defer { DesignSettings.shared.densityTokens = saved }
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var samples: [Double] = []
        var applies: [Double] = []
        for tick in 0..<40 {
            let start = ContinuousClock.now
            mine = DensityTokenCatalog.setting(gap, to: Double(tick % 8), in: mine)
            DesignSettings.shared.densityTokens = mine
            let applied = ContinuousClock.now
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            applies.append(ms(applied - start))
            samples.append(ms(ContinuousClock.now - start))
        }
        let median = samples.sorted()[samples.count / 2]
        let applyMedian = applies.sorted()[applies.count / 2]
        print("density-playground tick: median \(String(format: "%.2f", median)) ms (apply \(String(format: "%.3f", applyMedian)) ms), "
            + "max \(String(format: "%.2f", samples.max() ?? 0)) ms over \(samples.count)")
        #expect(median < 16, "median \(median) ms")
    }

    // MARK: Fixtures

    struct Fixture {
        let model: DensityPlaygroundModel
        let design: DesignSettings
        let recorder: Recorder
        var saves: [(customs: [DensityTokens], active: DensityTokens)] { recorder.saves }
    }

    final class Recorder { var saves: [(customs: [DensityTokens], active: DensityTokens)] = [] }

    static func fixture(active: DensityTokens) -> Fixture {
        let design = DesignSettings()
        design.densityTokens = active
        let recorder = Recorder()
        let model = DensityPlaygroundModel(entries: entries, design: design) { customs, active in
            recorder.saves.append((customs, active))
        }
        return Fixture(model: model, design: design, recorder: recorder)
    }

    static func sidebar() -> SidebarView {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-one"), title: "density playground")),
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-two"), title: "vertical tabs")),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }
}
