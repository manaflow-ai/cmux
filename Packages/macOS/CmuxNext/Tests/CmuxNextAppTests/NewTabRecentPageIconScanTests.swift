import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Observation
import Testing

/// A RECENT PAGE's ICON AND THE WORKSPACES OF THE SESSION.
///
/// A New Tab page lists the recent pages of the browser's history (at most 40), each with its site's icon. The
/// page's build (`NewTabPage.omnibar`) asks for each recent page which icon address an open tab of that site shows
/// (`AppServices.siteFavicon`, then `siteFaviconAddress(origin:)`). That question walks the workspaces of this Mac,
/// each screen, pane and tab of each, to the first open tab of the site. A recent page whose site is in no open tab
/// (the usual case) walks ALL of them. The build runs at each New Tab key, so the work of one key grows with the
/// count of recent pages times the size of the session.
///
/// The rule: the icon address of a recent page reads no workspace of the session. (The sidebar's links have the same
/// question and a kept table for it, `OpenTabFavicons`, with one observation for each workspace.)
///
/// The count, with no clock: the question for 3 recent pages runs inside ONE `withObservationTracking`. Then one
/// workspace gets a new terminal tab, by the store's intent as the key does it. When that write wakes the tracking,
/// the question read that workspace's tab list. The row does this for EACH workspace of a session of 2 and of a
/// session of 60, and counts the workspaces whose new tab woke the tracking: a count that is the session's size is
/// a walk of the session.
///
/// Limits: the row asks the question directly, not through a whole build of the page. A whole build also reads the
/// rows of the bar's open tabs, and its favicon store starts a network fetch for the icon of an http(s) page, which
/// a test must not do. The row counts the read of a workspace, not the time of it. It does not count the PNG encode
/// of each icon and not the sort of the history: they are other costs of the same build.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct NewTabRecentPageIconScanTests {
    /// Set by a tracking's `onChange`, in the write that woke it.
    private nonisolated final class Flag: @unchecked Sendable {
        var woke = false
    }

    private static func key(_ workspace: Int) -> String { "recent-icon-scan-ws-\(workspace)" }

    /// The site origins of 3 recent pages. No tab of the scene shows one of them.
    private static let sites = ["https://recent-1.example", "https://recent-2.example", "https://recent-3.example"]

    /// `workspaces` workspaces, each one screen with one pane of two terminals and one WebKit page.
    private static func tree(workspaces: Int) -> DaemonTree {
        let snapshots = (1...workspaces).map { workspace in
            let first = UInt64((workspace - 1) * 3)
            let tabs = [
                TabSnapshot(surface: SurfaceID(rawValue: first + 1), title: "zsh"),
                TabSnapshot(surface: SurfaceID(rawValue: first + 2), title: "zsh"),
                TabSnapshot(surface: SurfaceID(rawValue: first + 3), kind: .browser, url: "http://127.0.0.1:9/\(workspace)",
                            browserRenderer: "frontend", browserEngine: "webkit"),
            ]
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(workspace)), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: WorkspaceKey(rawValue: key(workspace)),
                                     name: "workspace \(workspace)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: snapshots)
        tree.personal = PersonalState(workspaces: (1...workspaces).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key($0)), index: $0 - 1)
        })
        return tree
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// In how many of the `workspaces` workspaces a new terminal tab woke a tracking of the icon addresses of
    /// `sites`. The app is a whole window of a session of `workspaces` workspaces (the last one shows), as
    /// `CmdTTabListReadersTests` makes it. Each workspace gets a tracking of its own, and then its new tab.
    private static func wokenWorkspaces(workspaces: Int, sites: [String]) async throws -> Int {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(workspaces: workspaces))
        try #require(store.workspaces.count == workspaces, "fixture: \(store.workspaces.count) workspaces, not \(workspaces)")
        try #require(services.machines.local.store.workspaces.count == workspaces,
                     "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not \(workspaces)")

        let keys = [key(workspaces)] + (1..<workspaces).map(key)
        // What the observed lists read in the turn of the window's set-up (each owner of an observed list counts
        // here, not the icons' table alone): read directly after the call, with no turn between.
        let work = ObservationWork()
        let opened = ObservationWork.$current.withValue(work) {
            services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900))
        }
        let reads = work.byStep.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("NewTabRecentPageIconScanTests: \(workspaces) workspaces: the observed lists read in the turn of the window's set-up: [\(reads)]")
        let controller = try #require(opened)
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await drainMain() }
        try #require(controller.workspaceContent).contentView.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await drainMain() }
        // One question outside a tracking first: the count is of a reader that is not the first one that asks.
        _ = services.siteFaviconAddress(origin: "https://recent-0.example")
        await drainMain()

        var woken = 0
        for number in 1...workspaces {
            let workspace = try #require(store.workspaces.first { $0.key?.rawValue == key(number) }, "fixture: no workspace \(number)")
            let pane = try #require(workspace.screens.first?.panes.first, "fixture: workspace \(number) has no pane")
            let flag = Flag()
            let addresses = withObservationTracking { sites.map { services.siteFaviconAddress(origin: $0) } } onChange: { flag.woke = true }
            // No open tab shows one of the sites: each answer is the site's own address, after a walk to the end.
            try #require(addresses == sites.map { $0 + "/favicon.ico" }, "fixture: the icon addresses are \(addresses)")
            let before = pane.tabs.count
            store.intend(.createTab(pane: pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                         transaction: ClientTransactionID.generate())
            try #require(pane.tabs.count == before + 1, "fixture: the intent made \(pane.tabs.count - before) tabs in workspace \(number), not 1")
            // The will-set of a write runs a tracking's `onChange` in the write. A wake that comes through the kept
            // table comes some turns later (the workspace's watch task, then a write of the table). The flag is read
            // after the main actor ran, so it has each of the 2 kinds of wake.
            await drainMain()
            if flag.woke { woken += 1 }
        }
        return woken
    }

    /// RED before the mend: the question walks each workspace, so each workspace's new tab wakes its tracking.
    @Test func theIconAddressOfARecentPageReadsNoWorkspaceOfTheSession() async throws {
        var counts: [(size: Int, woken: Int)] = []
        for size in [2, 60] {
            let woken = try await Self.wokenWorkspaces(workspaces: size, sites: Self.sites)
            counts.append((size, woken))
        }
        print("NewTabRecentPageIconScanTests: row 1, the icon addresses of 3 recent pages of sites that no tab shows: "
            + counts.map { "\($0.size) workspaces: a new tab woke the read in \($0.woken) of \($0.size) workspaces" }.joined(separator: " | "))
        for count in counts {
            #expect(count.woken == 0,
                    "with \(count.size) workspaces the icon addresses of 3 recent pages read the tab list of \(count.woken) workspaces")
        }
    }

    /// The control: with no recent page the same tracking reads nothing, so no new tab wakes it.
    @Test func withNoRecentPageNoNewTabWakesTheRead() async throws {
        let woken = try await Self.wokenWorkspaces(workspaces: 2, sites: [])
        print("NewTabRecentPageIconScanTests: row 2, the control, no recent page: 2 workspaces: a new tab woke the read in \(woken) of 2 workspaces")
        #expect(woken == 0, "with no recent page a new tab woke the tracking in \(woken) workspaces")
    }
}
