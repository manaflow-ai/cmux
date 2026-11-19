import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Selecting a tab never moves or resizes any tab (Lawrence 2026-10-19, "changing tab changes tab
/// width, which is bad"). Tab geometry is a function of the pane's tabs and width only: tabs coming
/// and going, a rename or a pane resize may change it, a selection never does.
///
/// The repro was a pane whose "…" (`PaneToolbar`) showed only for some selected tabs (none for a
/// window's own page tab or a chat): the strip gave the "…" its width while it showed, so every tab
/// shrank and grew as the selection moved. The second case was Chrome's crowded strip, where the
/// selected tab kept a larger minimum than the others.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabSelectionKeepsTabWidthsTests {
    private struct Geometry: Equatable, CustomStringConvertible {
        let strip: NSRect
        let slots: [String]
        var description: String { "strip \(strip), slots \(slots)" }
    }

    private static func geometry(_ strip: TabStripView, in pane: NSView? = nil) -> Geometry {
        Geometry(strip: pane == nil ? .zero : strip.frame,
                 slots: strip.result.slots.map { "\($0.id.rawValue)@\($0.x)+\($0.width)" })
    }

    /// A pane with store tabs (they offer "…") and local page tabs (they do not): every selection
    /// lays the strip out the same.
    @Test func selectingATabThatOffersNoMoreMenuKeepsEveryTabInPlace() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let ids = (0..<11).map { $0 % 3 == 2 ? "\(LocalPageTab.prefix)page\($0)" : "tab\($0)" }
        let model = TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: "cmux-prompt-commits \($0)") }, selectedID: TabID(ids[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.frame = NSRect(x: 0, y: 0, width: 1280, height: 300)
        window.contentView = pane
        let toolbar = PaneToolbar(registry: { nil })
        pane.toolbar = toolbar

        var seen: [String: Geometry] = [:]
        for id in ids {
            model.selectedID = TabID(id)
            // What `PaneToolbar.state` reads for this selection: a local page tab has no "…".
            let local = id.hasPrefix(LocalPageTab.prefix)
            toolbar.update(target: local ? nil : id, kind: local ? nil : .terminal, paneKinds: [.terminal])
            pane.stripView.syncFromModel()
            pane.layoutSubtreeIfNeeded()
            pane.stripView.layoutSubtreeIfNeeded()
            seen[id] = Self.geometry(pane.stripView, in: pane)
        }
        let first = try #require(seen[ids[0]])
        for id in ids {
            #expect(seen[id] == first, "selecting \(id) laid the strip out as \(String(describing: seen[id])), not \(first)")
        }
    }

    /// A strip too narrow for every tab at its width: all tabs share the same width whichever is
    /// selected (no larger selected minimum that pushes the others).
    @Test func selectingATabInACrowdedStripKeepsEveryTabInPlace() throws {
        DesignSettings.shared.tabOverflow = .shrink
        let ids = (0..<30).map { "tab\($0)" }
        let model = TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: "Tab \($0)") }, selectedID: TabID(ids[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        // The case this guards needs a share between the two minimums. Since 9d31a6eb78b the default inactive
        // minimum (the favicon, the close button and 24 pt of title room) equals the active one, so a crowded
        // strip scrolls at that width; the strip pins the two minimums apart here, as a person's
        // `appearance.metrics.tabMinInactiveWidth` can.
        var metrics = TabStripMetrics()
        metrics.minInactiveTabWidth = 32
        metrics.minActiveTabWidth = 72
        strip.customMetrics = metrics
        // 30 tabs in 1200 pt: 40 each, under the selected minimum and over the inactive one.
        strip.frame = NSRect(x: 0, y: 0, width: 1200, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        let first = Self.geometry(strip)
        // Even shares: whole points, the leftover points on the leading tabs (`TabLayoutEngine.distribute`).
        let widths = strip.result.slots.map(\.width)
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1, "\(Set(widths))")
        #expect((widths.min() ?? 0) < strip.metrics.minActiveTabWidth, "the strip is not crowded: \(Set(widths))")
        for id in ids {
            model.selectedID = TabID(id)
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            #expect(Self.geometry(strip) == first, "selecting \(id) moved tabs")
        }
    }

    // MARK: experiments.tabBarStyle

    /// A strip of `count` tabs in a window, read under `style` (restored to `.off` by the caller's defer).
    private static func styledStrip(_ style: TabBarStyleExperiment, count: Int = 6) -> (NSWindow, TabStripView, TabStripModel) {
        DesignSettings.shared.tabOverflow = .shrink
        DesignSettings.shared.tabBarStyleExperiment = style
        let ids = (0..<count).map { "tab\($0)" }
        let model = TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: "A longer title \($0)") }, selectedID: TabID(ids[0]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 1200, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        return (window, strip, model)
    }

    /// Off is the shipped strip: none of the looks' layers, the shipped + width and separators setting.
    @Test func barStyleOffDrawsNoStyleLayers() {
        let (window, strip, _) = Self.styledStrip(.off)
        defer { window.closeAfterTest() }
        #expect(strip.metrics.barStyle == .off)
        #expect(strip.barStyleBackdrop == nil && strip.barStyleHairline == nil)
        #expect(strip.metrics.newTabButtonWidth == TitlebarBandButton.side)
        #expect(strip.metrics.showsSeparators == TabTunables.separators.value)
        #expect(strip.metrics.glassInset == 0 && strip.metrics.glassButtonGap == 0)
    }

    /// Underline: bolding the selected label never moves a tab, and only the selected tab has the rule.
    @Test func underlineSelectionKeepsEveryTabInPlace() throws {
        let (window, strip, model) = Self.styledStrip(.underline)
        defer {
            window.closeAfterTest()
            DesignSettings.shared.tabBarStyleExperiment = .off
        }
        #expect(strip.barStyleHairline != nil && strip.barStyleBackdrop == nil)
        #expect(!strip.metrics.showsSeparators)
        let first = Self.geometry(strip)
        for id in model.tabs.map(\.id) {
            model.selectedID = id
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
            #expect(Self.geometry(strip) == first, "selecting \(id.rawValue) moved tabs")
            let cell = try #require(strip.cells[id])
            #expect(cell.underlineLayer != nil)
            #expect(cell.titleLayer.font.pointSize == cell.titleFont.pointSize)
            #expect(strip.cells.values.filter { $0.underlineLayer != nil }.count == 1)
        }
    }

    /// Switching the look restyles a live strip: the glass capsule and its round + come and go with the setting.
    @Test func glassLookRestylesLiveAndBack() {
        let (window, strip, _) = Self.styledStrip(.off)
        defer {
            window.closeAfterTest()
            DesignSettings.shared.tabBarStyleExperiment = .off
        }
        DesignSettings.shared.tabBarStyleExperiment = .glass
        strip.customMetrics = nil // re-reads the tokens now, as the token observation does on the next turn
        strip.layoutSubtreeIfNeeded()
        #expect(strip.metrics.barStyle == .glass)
        #expect(strip.barStyleBackdrop != nil && strip.newTabButton.glassCircle)
        #expect(strip.metrics.newTabButtonWidth >= strip.metrics.tabHeight)
        DesignSettings.shared.tabBarStyleExperiment = .off
        strip.customMetrics = nil
        strip.layoutSubtreeIfNeeded()
        #expect(strip.barStyleBackdrop == nil && !strip.newTabButton.glassCircle)
    }
}
