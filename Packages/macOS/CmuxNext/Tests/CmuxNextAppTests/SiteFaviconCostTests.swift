import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// Hot-path audit 3, H5 (2026-10-28): each omnibar suggestion row, bookmark, New Tab page item and sidebar link
/// asks for its site's icon (`AppServices.siteFaviconAddress`), and `openTabFaviconsByOrigin` builds the link rows'
/// table. Each call walked every workspace, screen, pane and tab of the local store and parsed each browser tab's
/// URL: O(tabs) per row, and the observations that read them heard every pane's tab list, so a terminal opened
/// anywhere re-ran them. An index of the open browser tabs by site, kept by each browser change (`StoreTabRoles`),
/// answers a row with the tabs of its site alone.
@MainActor @Suite(.serialized) struct SiteFaviconCostTests {
    /// Set from an observation's change callback.
    nonisolated final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        nonisolated var fired: Bool { lock.withLock { value } }
        nonisolated func fire() { lock.withLock { value = true } }
    }

    static let siteSurface: SurfaceID = 90_000_001

    /// `workspaces` workspaces (handle w, screen w, pane w) of `terminals` terminals and one browser tab on
    /// `https://site<w>.example` each; workspace 1's browser tab is on `https://docs.example` with its icon.
    static func tree(workspaces: Int, terminals: Int) -> DaemonTree {
        DaemonTree(workspaces: (1...workspaces).map { w in
            var tabs = (0..<terminals).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 1_000 + $0)), title: "zsh") }
            tabs.append(w == 1
                ? TabSnapshot(surface: siteSurface, kind: .browser, title: "Docs", url: "https://docs.example/guide",
                              faviconURL: "https://docs.example/static/icon.png")
                : TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 1_000 + 999)), kind: .browser, title: "Site \(w)",
                              url: "https://site\(w).example/page", faviconURL: "https://site\(w).example/i.png"))
            let pane = PaneID(rawValue: UInt64(w))
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(w)), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(w)), key: nil, name: "w\(w)", screens: [screen])
        })
    }

    static func services(workspaces: Int, terminals: Int) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: tree(workspaces: workspaces, terminals: terminals))
        return services
    }

    static func terminalAdded(workspace w: UInt64, surface: UInt64) -> DaemonEvent {
        .tabAdded(TabDelta(workspace: WorkspaceHandle(rawValue: w), screen: ScreenID(rawValue: w), pane: PaneID(rawValue: w),
                           surface: SurfaceID(rawValue: surface), index: nil, entity: TabSnapshot(surface: SurfaceID(rawValue: surface), title: "zsh")))
    }

    @Test func aTerminalOpenedAnywhereReRunsNoSiteIconRead() {
        let services = Self.services(workspaces: 100, terminals: 4)
        let fired = Fired()
        let (address, table) = withObservationTracking {
            (services.siteFaviconAddress(origin: "https://docs.example"), services.openTabFaviconsByOrigin())
        } onChange: { fired.fire() }
        #expect(address == "https://docs.example/static/icon.png", "an open tab's icon")
        #expect(table["https://site50.example"] == "https://site50.example/i.png" && table.count == 100)
        let store = services.machines.local.store
        store.apply(Self.terminalAdded(workspace: 70, surface: 70_998))
        store.apply(Self.terminalAdded(workspace: 1, surface: 1_998))
        #expect(!fired.fired, "a terminal opened in a workspace re-ran a site icon read (every suggestion row, link and bookmark)")
    }

    @Test func aBrowserTabsNavigationAndCloseReachTheRead() throws {
        let services = Self.services(workspaces: 10, terminals: 2)
        let store = services.machines.local.store
        #expect(services.siteFaviconAddress(origin: "https://other.example") == "https://other.example/favicon.ico", "no open tab: the site's own")
        let fired = Fired()
        _ = withObservationTracking { services.siteFaviconAddress(origin: "https://docs.example") } onChange: { fired.fire() }
        // The docs tab navigates to another site: docs has no open tab, the other site has its icon.
        let moved = TabSnapshot(surface: Self.siteSurface, kind: .browser, title: "Other", url: "https://other.example/a",
                                faviconURL: "https://other.example/o.svg")
        store.apply(.tabChanged(TabDelta(workspace: 1, screen: 1, pane: 1, surface: Self.siteSurface, index: nil, entity: moved)))
        #expect(fired.fired, "a browser tab's navigation must reach a reader of its site's icon")
        #expect(services.siteFaviconAddress(origin: "https://docs.example") == "https://docs.example/favicon.ico")
        #expect(services.siteFaviconAddress(origin: "https://other.example") == "https://other.example/o.svg")
        #expect(services.openTabFaviconsByOrigin()["https://other.example"] == "https://other.example/o.svg")
        store.apply(.tabClosed(TabDelta(workspace: 1, screen: 1, pane: 1, surface: Self.siteSurface, index: nil, entity: moved)))
        #expect(services.siteFaviconAddress(origin: "https://other.example") == "https://other.example/favicon.ico")
        #expect(services.openTabFaviconsByOrigin()["https://other.example"] == nil)
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    /// One omnibar suggestion list's icon lookups (8 rows) against the session's size: BENCH lines at 10, 100 and
    /// 1000 workspaces of 4 terminals and one browser tab each.
    @Test func benchEightRowLookupsAtTenAHundredAndAThousandWorkspaces() {
        var medians: [Int: Double] = [:]
        let origins = ["https://docs.example", "https://site2.example", "https://site9.example", "https://none.example",
                       "https://a.example", "https://b.example", "https://site5.example", "https://c.example"]
        for workspaces in [10, 100, 1_000] {
            let services = Self.services(workspaces: workspaces, terminals: 4)
            var samples: [Double] = []
            for _ in 0..<51 {
                let start = ContinuousClock.now
                for origin in origins { _ = services.siteFaviconAddress(origin: origin) }
                samples.append(Self.microseconds(ContinuousClock.now - start))
            }
            medians[workspaces] = samples.sorted()[samples.count / 2]
            print("BENCH H5 site-favicon-8-rows workspaces=\(workspaces) tabs=\(workspaces * 5) median_us=\(String(format: "%.2f", medians[workspaces] ?? 0))")
        }
        print("BENCH H5 site-favicon-8-rows ratio_1000_over_10=\(String(format: "%.1f", (medians[1_000] ?? 0) / max(medians[10] ?? 1, 0.001)))")
    }

    @Test func anIncognitoWindowsTabLendsNoIcon() throws {
        let services = Self.services(workspaces: 3, terminals: 1)
        let docs = try #require(services.machines.local.store.workspaces.first)
        #expect(services.siteFaviconAddress(origin: "https://docs.example") == "https://docs.example/static/icon.png")
        services.windows.registry.apply { registry in
            registry = WindowRegistry(windows: [.init(id: "private", workspaceIDs: [docs.id])])
            registry.markIncognito("private")
            return WindowRegistry.Changes()
        }
        #expect(services.siteFaviconAddress(origin: "https://docs.example") == "https://docs.example/favicon.ico",
                "an incognito window's tab lent its icon")
        #expect(services.openTabFaviconsByOrigin()["https://docs.example"] == nil)
    }
}
