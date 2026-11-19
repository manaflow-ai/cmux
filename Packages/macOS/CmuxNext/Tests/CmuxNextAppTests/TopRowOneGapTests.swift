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
/// - between the sidebar's edge and the first tab,
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

    /// Every built-in density and a custom one with a wider strip padding than any built-in.
    static var densities: [DensityTokens] {
        var custom = DensityPreset.cozy.tokens
        custom = DensityTokens(id: "custom-roomy", name: "Custom roomy", basedOn: DensityPreset.cozy.rawValue, level: custom.level,
                               spacing: custom.spacing, fontSize: custom.fontSize, tokens: custom.tokens.merging(["browserRowGap": 5]) { $1 })
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
        var bar: CGRect?
        var page: CGRect?
        var barInset: CGFloat

        var description: String {
            func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
            let bar = bar.map { "bar \(f($0.minY))..\(f($0.maxY))" } ?? "no bar"
            return "scale \(f(scale)) rim \(f(rim)) gap \(f(gap)) lights mid \(f(lights.midY)) x \(f(lights.minX)) toggle mid \(f(toggle.midY)) "
                + "pill \(f(pill.minX)),\(f(pill.minY)) \(f(pill.width))x\(f(pill.height)) mid \(f(pill.midY)) sidebar edge \(f(sidebarEdge)) "
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
                   lights: lights, toggle: toggle, pill: pill, sidebarEdge: sidebar.maxX,
                   bar: chrome.map { topLeft($0.addressBar, in: window) }, page: chrome.map { topLeft($0.contentContainer, in: window) },
                   barInset: barInset)
    }

    /// One device pixel.
    private func pixel(_ row: Row) -> CGFloat { 1 / max(row.scale, 1) + 0.001 }

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
        #expect(abs((row.pill.minX - row.sidebarEdge) - row.gap) <= pixel(row),
                "\(density.id): \(row.pill.minX - row.sidebarEdge) pt between the sidebar and the first tab, the strip padding is \(row.gap)")
        let bar = try #require(row.bar, "\(density.id): no omnibar"), page = try #require(row.page)
        #expect(abs((bar.minY - row.pill.maxY) - (row.gap + row.barInset)) <= pixel(row),
                "\(density.id): \(bar.minY - row.pill.maxY) pt between the tab and the omnibar, the strip padding is \(row.gap) (+ \(row.barInset))")
        #expect(abs((page.minY - bar.maxY) - (row.gap + row.barInset)) <= pixel(row),
                "\(density.id): \(page.minY - bar.maxY) pt between the omnibar and the page, the strip padding is \(row.gap) (+ \(row.barInset))")

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
}
