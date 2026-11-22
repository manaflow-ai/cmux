import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// The top row of a real window, measured from its views at every density (user 2026-11-19, msg 40554: "top padding is
/// not equal to left padding for the tab, also traffic lights not aligned"; msg 40580: "space between omnibar/content
/// is same as space between omnibar and tab, (which is coincidentally same as space between tabs and top)"; msg 40586:
/// "the way we set titlebar position is also very inconsistent"). One gap, the strip padding
/// (`PaneChromeMetrics.tabGap`, the density's `browserRowGap`), sits
///
/// - between the window's top edge (under its lit rim) and the first tab,
/// - between the main pane card's leading edge (the line beside the sidebar) and the first tab,
/// - between the tab and the omnibar, and between the omnibar and the page;
///
/// and the traffic lights, the toolbar band's buttons and the tab share the tab's center line, also after the window's
/// title changes (AppKit lays its titlebar out again then, without the root view's layout).
@MainActor @Suite(.serialized, .closesItsWindows) struct TopRowOneGapTests {
    /// One workspace whose pane shows a browser tab (so the omnibar row is there), with a terminal tab beside it.
    static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), activeTab: 0, tabs: [
            TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, title: "Page", url: "https://example.com/"),
            TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~"),
        ])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k0"), name: "k0",
                              screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k0"), index: 0)])
        return tree
    }

    /// Every built-in density and a custom one with a wider strip padding than any built-in. Nonisolated: the test's
    /// arguments are read before it runs on the main actor.
    nonisolated static var densities: [DensityTokens] {
        var custom = DensityPreset.cozy.tokens
        custom = DensityTokens(id: "custom-roomy", name: "Custom roomy", basedOn: DensityPreset.cozy.rawValue, level: custom.level,
                               spacing: custom.spacing, fontSize: custom.fontSize, tokens: custom.tokens.merging(["browserRowGap": 7]) { $1 })
        return DensityPreset.allCases.map(\.tokens) + [custom]
    }

    /// The top row's frames in window points from the top-left.
    struct Row: CustomStringConvertible {
        var scale: CGFloat
        var rim: CGFloat
        var gap: CGFloat
        var lights: CGRect
        var toggle: CGRect
        var pill: CGRect
        var sidebarEdge: CGFloat
        var card: CGRect
        var bar: CGRect?
        var page: CGRect?
        var barInset: CGFloat
        /// The omnibar row's gap above and below the bar (`OmnibarStyle.rowGap`): the strip padding, Chrome's 6 at Default.
        var barGap: CGFloat

        var description: String {
            func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
            let bar = bar.map { "bar \(f($0.minY))..\(f($0.maxY))" } ?? "no bar"
            return "scale \(f(scale)) rim \(f(rim)) gap \(f(gap)) lights mid \(f(lights.midY)) x \(f(lights.minX)) toggle mid \(f(toggle.midY)) "
                + "pill \(f(pill.minX)),\(f(pill.minY)) \(f(pill.width))x\(f(pill.height)) mid \(f(pill.midY)) sidebar edge \(f(sidebarEdge)) "
                + "card \(f(card.minX)),\(f(card.minY)) "
                + "\(bar) page top \(page.map { f($0.minY) } ?? "-")"
        }
    }

    private func topLeft(_ view: NSView, in window: NSWindow) -> CGRect {
        let rect = view.convert(view.bounds, to: nil)
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var out: [T] = [], pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1 { out.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return out
    }

    private func measure(_ fixture: SidebarMultiViewWindowTests.Fixture) throws -> Row {
        let window = try #require(fixture.controller.window)
        let content = try #require(window.contentView)
        let height = content.bounds.height
        let scale = window.backingScaleFactor
        let lightsInWindow = try #require(WindowTitlebar.trafficLightsFrame(in: window), "no traffic lights")
        let lights = CGRect(x: lightsInWindow.minX, y: height - lightsInWindow.maxY, width: lightsInWindow.width, height: lightsInWindow.height)
        let root = fixture.controller.root
        let toggle = topLeft(root.toolbarBand.sidebarToggle, in: window)
        // The top row's strip: the topmost shown one.
        let strip = try #require(views(TabStripView.self, in: content).min { topLeft($0, in: window).minY < topLeft($1, in: window).minY },
                                 "no tab strip")
        let pillInStrip = try #require(strip.firstTabPillFrame, "the strip has no tab")
        let pillInWindow = strip.convert(strip.isFlipped ? pillInStrip : CGRect(x: pillInStrip.minX, y: strip.bounds.height - pillInStrip.maxY,
                                                                                width: pillInStrip.width, height: pillInStrip.height), to: nil)
        let pill = CGRect(x: pillInWindow.minX, y: height - pillInWindow.maxY, width: pillInWindow.width, height: pillInWindow.height)
        let sidebar = topLeft(fixture.controller.sidebar.container, in: window)
        let chrome = views(BrowserChromeView.self, in: content).first
        let barInset = chrome.map { (max($0.addressBar.bounds.height, $0.reloadButton.bounds.height) - $0.addressBar.bounds.height) / 2 } ?? 0
        return Row(scale: scale, rim: WindowTitlebar.topRowRim(in: window), gap: PaneChromeMetrics.current.tabGap(scale: scale),
                   lights: lights, toggle: toggle, pill: pill, sidebarEdge: sidebar.maxX, card: topLeft(root.contentHost, in: window),
                   bar: chrome.map { topLeft($0.addressBar, in: window) }, page: chrome.map { topLeft($0.contentContainer, in: window) },
                   barInset: barInset, barGap: OmnibarStyle.rowGap(scale: scale, underStrip: true))
    }

    /// One device pixel of the user's 2x display: a 1x worker rounds to whole points, so its own pixel would hide a
    /// line one point off (the lights 1 pt under the tabs at Default and above before this fix).
    private func pixel(_ row: Row) -> CGFloat { 0.5 + 0.001 }

    private func expectOneLine(_ row: Row, _ name: String, _ when: String) {
        #expect(abs(row.lights.midY - row.pill.midY) <= pixel(row), "\(name) \(when): the lights center at \(row.lights.midY), the tab at \(row.pill.midY)")
        #expect(abs(row.toggle.midY - row.pill.midY) <= pixel(row), "\(name) \(when): the sidebar toggle centers at \(row.toggle.midY), the tab at \(row.pill.midY)")
    }

    @Test(arguments: TopRowOneGapTests.densities.map(\.id))
    func theTopRowKeepsOneGapAndOneLine(densityID: String) async throws {
        let density = try #require(Self.densities.first { $0.id == densityID })
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titlebar, design.tabBarPosition)
        defer { (design.densityTokens, design.titlebar, design.tabBarPosition) = saved }
        design.densityTokens = density
        design.titlebar = .minimal
        design.tabBarPosition = .top
        let fixture = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0"], tree: Self.tree())
        defer { fixture.close() }
        fixture.frame()
        let row = try measure(fixture)
        print("TOPROW|\(density.id)|\(row)")
        expectOneLine(row, density.id, "at rest")
        #expect(abs((row.pill.minY - row.rim) - row.gap) <= pixel(row),
                "\(density.id): \(row.pill.minY - row.rim) pt between the window's top edge and the first tab, the strip padding is \(row.gap)")
        #expect(abs((row.pill.minX - row.card.minX) - row.gap) <= pixel(row),
                "\(density.id): \(row.pill.minX - row.card.minX) pt between the card's leading edge and the first tab, the strip padding is \(row.gap)")
        // The window shows an omnibar where its browser engine runs; the omnibar row's own gaps at every density are
        // `theOmnibarRowKeepsTheStripPadding`.
        if let bar = row.bar, let page = row.page {
            #expect(abs((bar.minY - row.pill.maxY) - (row.barGap + row.barInset)) <= pixel(row),
                    "\(density.id): \(bar.minY - row.pill.maxY) pt between the tab and the omnibar, the row's gap is \(row.barGap) (+ \(row.barInset))")
            #expect(abs((page.minY - bar.maxY) - (row.barGap + row.barInset)) <= pixel(row),
                    "\(density.id): \(page.minY - bar.maxY) pt between the omnibar and the page, the row's gap is \(row.barGap) (+ \(row.barInset))")
        }

        // A title change: AppKit lays the titlebar out again, and the lights must stay on the line.
        let workspace = try #require(fixture.services.machines.workspace(id: "k0")?.0)
        workspace.name = "Renamed workspace"
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.controller.window?.title.contains("Renamed workspace") != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fixture.frame()
        }
        try #require(fixture.controller.window?.title.contains("Renamed workspace") == true, "the title did not change")
        fixture.controller.window?.displayIfNeeded()
        let renamed = try measure(fixture)
        print("TOPROW|\(density.id)|after title|\(renamed)")
        expectOneLine(renamed, density.id, "after a title change")

        // The window turns dark and light: AppKit redraws its titlebar.
        let window = try #require(fixture.controller.window)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            fixture.frame()
            let themed = try measure(fixture)
            print("TOPROW|\(density.id)|after \(appearance.rawValue)|\(themed)")
            expectOneLine(themed, density.id, "after \(appearance.rawValue)")
        }
    }

    /// A browser pane's chrome under `density`, measured from its views: the strip padding under the tab pills, the bar's
    /// centering in the row's toolbar buttons, the room from the pills' bottom (or a pane outline's top line) to the bar,
    /// from the bar to the page, and the bar's height.
    struct OmnibarRow {
        var gap: CGFloat
        var inset: CGFloat
        var above: CGFloat
        var below: CGFloat
        var barHeight: CGFloat
        /// `OmnibarStyle.rowGap`: the strip padding, Chrome's 6 at Default.
        var rowGap: CGFloat
    }

    /// `meetsTabStrip`: the pane shows its strip right above the toolbar, as a pane with tabs on top does.
    private func omnibarRow(_ density: DensityTokens, meetsTabStrip: Bool = true) -> OmnibarRow {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = density
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let chrome = BrowserChromeView(tab: tab)
        chrome.meetsTabStrip = meetsTabStrip
        chrome.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let gap = PaneChromeMetrics.current.tabGap(scale: window.backingScaleFactor)
        let top = topLeft(chrome, in: window).minY, bar = topLeft(chrome.addressBar, in: window), page = topLeft(chrome.contentContainer, in: window)
        let inset = (max(chrome.addressBar.bounds.height, chrome.reloadButton.bounds.height) - chrome.addressBar.bounds.height) / 2
        let above = Metrics.paneBorder == .subtle ? bar.minY - top - (Metrics.paneBorderWidth ?? 1 / window.backingScaleFactor) : bar.minY - top + gap
        return OmnibarRow(gap: gap, inset: inset, above: above, below: page.minY - bar.maxY, barHeight: bar.height,
                          rowGap: OmnibarStyle.rowGap(scale: window.backingScaleFactor, underStrip: meetsTabStrip))
    }

    /// The omnibar row under the tabs, at every density: the strip padding under the tab pills (the strip's bottom is the
    /// chrome's top) plus the room above the bar equals the room under it to the page (user 2026-11-19, msg 40580). The
    /// bar is centered in the row's tallest thing, the toolbar buttons, so both sides add that centering. The row's gap is
    /// the strip padding at every built-in but Default, whose is Chrome's 6 (`defaultsOmnibarRowHasChromesSixPointGaps`).
    @Test(arguments: TopRowOneGapTests.densities.map(\.id))
    func theOmnibarRowKeepsTheStripPadding(densityID: String) throws {
        let density = try #require(Self.densities.first { $0.id == densityID })
        let row = omnibarRow(density)
        let (gap, inset, above, below) = (row.rowGap, row.inset, row.above, row.below)
        print("TOPROW|\(density.id)|omnibar|strip \(row.gap) gap \(gap) inset \(inset) above \(above) below \(below)")
        // Default's own is Chrome's 6, Comfortable's 6.5 and Spacious's 7.5 (6 times their factor, Spacious a half point more); Ultra-compact, Compact and a
        // custom one whose strip padding is past its omnibar gap keep the strip padding.
        let chromeRow: [String: CGFloat] = [DensityPreset.cozy.rawValue: 6, DensityPreset.comfortable.rawValue: 6.5, DensityPreset.spacious.rawValue: 7.5]
        // On the screen's pixel grid, as `OmnibarStyle.rowGap` snaps it (a 1x screen draws 6.5 as 7).
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        let want: CGFloat = chromeRow[density.id].map { ($0 * scale).rounded() / scale } ?? row.gap
        #expect(gap == want, "\(density.id): the omnibar row's gap is \(gap), want \(want)")
        // Compact's tabs sit 1 pt further from the bar than its strip padding (`tabToOmnibarGap`, Lucas 2026-11-20).
        let extra = CGFloat(density.tokens["tabToOmnibarGap"].map { max(0, $0 - Double(gap)) } ?? 0)
        #expect(abs(above - (gap + extra + inset)) <= 0.501, "\(density.id): \(above) pt between the tab and the omnibar, the row's gap is \(gap) (+ \(extra) + \(inset))")
        #expect(abs(below - (gap + inset)) <= 0.501, "\(density.id): \(below) pt between the omnibar and the page, the row's gap is \(gap) (+ \(inset))")
    }

    /// Default's omnibar row is Chrome's toolbar (Lucas 2026-11-20: "match chrome to be EXACTLY the same as chromium ...
    /// between the omnibar it should be 6px gap. so top-padding 6px bottom padding 6px"): Chrome's 34 pt bar with 6 pt from
    /// the tab pills to it and 6 pt from it to the page. Every other built-in keeps the strip padding there
    /// (`theOmnibarRowKeepsTheStripPadding`).
    @Test func defaultsOmnibarRowHasChromesSixPointGaps() {
        let row = omnibarRow(DensityPreset.cozy.tokens)
        print("TOPROW|cozy|chrome omnibar|gap \(row.gap) inset \(row.inset) above \(row.above) below \(row.below) bar \(row.barHeight)")
        #expect(row.barHeight == 34, "Default's bar is \(row.barHeight) pt, Chrome's is 34")
        #expect(abs(row.above - 6) <= 0.001, "Default: \(row.above) pt between the tab and the omnibar, Chrome's is 6")
        #expect(abs(row.below - 6) <= 0.001, "Default: \(row.below) pt between the omnibar and the page, Chrome's is 6")
    }

    /// Chrome's 6 pt omnibar row needs a tab strip its pane shows right above it (`ToolbarEdgeHosting.meetsTabStrip`, which
    /// the pane sets: vertical tabs, a hidden strip, tabs under the toolbar or at the bottom and a toolbar at the bottom
    /// all leave it false). Without one, Default's row keeps its strip padding, 5 pt above and below the bar, as before.
    @Test func defaultsChromeRowNeedsAStripRightAbove() {
        let row = omnibarRow(DensityPreset.cozy.tokens, meetsTabStrip: false)
        print("TOPROW|cozy|no strip above|gap \(row.gap) above \(row.above) below \(row.below)")
        #expect(row.gap == 5, "Default's strip padding is \(row.gap)")
        #expect(abs(row.above - 5) <= 0.001, "Default with no strip above: \(row.above) pt over the bar, the strip padding is 5")
        #expect(abs(row.below - 5) <= 0.001, "Default with no strip above: \(row.below) pt under the bar, the strip padding is 5")
    }
}
