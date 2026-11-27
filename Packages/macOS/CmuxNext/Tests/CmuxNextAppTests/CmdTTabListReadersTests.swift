import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextKeepAwake
@testable import CmuxNextSettings
import Foundation
import Testing

/// CMD-T BUDGET (2026-11-10): Cmd-T puts one tab in one pane's tab list (`PaneModel.insertTab`). With 60 workspaces
/// that write cost 3 ms of the key's turn, all of it in `ObservationTracking.cancel`: an observer that had read the
/// tab list of every pane of the session was cancelled (one registration per pane and per tab it read) and then read
/// the whole session again to re-arm. The cost of one key grew with the session (Lawrence's has 826 workspaces).
///
/// Three observers that live as long as the app read the session that way: the keep-awake service (one stream over
/// every tab) and the terminal clipboard-read service (one tracking over every terminal), which no test fixture
/// started (the app delegate does), and the browser host provider (one tracking over every pane's tabs, for the
/// browser tabs it announces). Each must read one workspace per observation, so a new tab re-reads its own workspace
/// only (PATTERNS.md targeted observation; Chromium's `TabStripModelObserver` is per tab strip).
///
/// The count: a new tab in each of a few workspaces, one at a time, as the key does it (the store's intent). An
/// observer instance (`ObservationWakes`: one stream, tracking or loop) that wakes for more than one of them read the
/// tab lists of more than one workspace. The session's size is the one argument; the answer must not depend on it.
@MainActor @Suite(.serialized)
struct CmdTTabListReadersTests {
    private static func key(_ workspace: Int) -> String { "readers-ws-\(workspace)" }
    /// The keep-awake services this suite started (the app has one, for its lifetime).
    private static var kept: [KeepAwakeService] = []

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

    /// For each observer instance that a new tab woke: its site and in how many of the changed workspaces a new tab
    /// woke it. The app is a whole window of a session of `workspaces` workspaces (the last one shows) with the two
    /// services the app delegate starts for the app's lifetime (`AppServices` starts the browser host itself).
    private static func workspacesReadPerObserver(workspaces: Int) async throws -> [(site: String, workspaces: Int)] {
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

        // As the app delegate: the clipboard-read service of the local daemon, and the keep-awake service once the
        // settings loaded.
        let clipboardReads = TerminalClipboardReadService(services: services)
        clipboardReads.start()
        defer { clipboardReads.stop() }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmd-t-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let keepAwake = KeepAwakeService()
        kept.append(keepAwake) // its power-source monitor has an unretained context: never freed in this process
        keepAwake.start(settings: settings, store: store)

        let keys = [key(workspaces)] + (1..<workspaces).map(key)
        let controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await drainMain() }
        try #require(controller.workspaceContent).contentView.layoutSubtreeIfNeeded()
        for _ in 0..<4 { await drainMain() } // every observer armed its first tracking

        // At most four workspaces, spread over the session; two are enough to see a reader of more than one.
        let changed = Array(Set([1, 2, max(1, workspaces / 2), workspaces])).sorted()
        var woken: [ObjectIdentifier: (site: String, workspaces: Int)] = [:]
        for number in changed {
            let workspace = try #require(store.workspaces.first { $0.key?.rawValue == key(number) }, "fixture: no workspace \(number)")
            let pane = try #require(workspace.screens.first?.panes.first, "fixture: workspace \(number) has no pane")
            let before = pane.tabs.count
            let wakes = ObservationWakes()
            ObservationWakes.$current.withValue(wakes) {
                store.intend(.createTab(pane: pane.handle, provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil)),
                             transaction: ClientTransactionID.generate())
            }
            try #require(pane.tabs.count == before + 1, "fixture: the intent made \(pane.tabs.count - before) tabs in workspace \(number), not 1")
            // The woken observers re-arm before the next workspace changes. A raw tracking counts its wake in the hop
            // its `onChange` queued (the hop has this scope's counter), so the count is read after the hops ran.
            await drainMain()
            for (instance, site) in wakes.woken { woken[instance, default: (site, 0)].workspaces += 1 }
        }
        try #require(changed.count >= 2, "fixture: \(changed.count) changed workspaces, not 2 or more")
        return Array(woken.values)
    }

    /// The three services, each by the files of its observations (a stream is named by the `#fileID:#line` where it
    /// was made). The browser host's tab list is read by its provider for the app's tab source.
    private static let appLifetimeServices: [(name: String, files: [String])] = [
        ("keep-awake", ["KeepAwakeService.swift"]),
        ("terminal clipboard reads", ["TerminalClipboardReadService.swift"]),
        ("browser host tabs", ["BrowserHostProvider+Tabs.swift", "AppBrowserHostTabs.swift"]),
    ]

    @Test(.timeLimit(.minutes(3)), arguments: [2, 60])
    func aNewTabWakesNoAppLifetimeObserverOfAnotherWorkspace(workspaces: Int) async throws {
        let observers = try await Self.workspacesReadPerObserver(workspaces: workspaces)
        // Every observer a new tab woke, also when the test passes: who reads a tab list, and of how many workspaces.
        let bySite = observers.reduce(into: [String: (instances: Int, most: Int)]()) { sites, observer in
            let old = sites[observer.site] ?? (0, 0)
            sites[observer.site] = (old.instances + 1, max(old.most, observer.workspaces))
        }
        for (site, count) in bySite.sorted(by: { $0.key < $1.key }) {
            print("tab list readers, \(workspaces) workspaces: \(site): \(count.instances) instances, one woke for \(count.most) workspaces")
        }
        let files = Self.appLifetimeServices.flatMap(\.files)
        let services = bySite.filter { site in files.contains { site.key.contains($0) } }
        for service in Self.appLifetimeServices {
            #expect(services.keys.contains { site in service.files.contains { site.contains($0) } },
                    "fixture: a new tab woke no observation of the \(service.name) service (it is not started, or not counted)")
        }
        let wide = services.filter { $0.value.most > 1 }.map { "\($0.key): \($0.value.most) workspaces" }.sorted()
        #expect(wide.isEmpty,
                "with \(workspaces) workspaces, one observation read the tab lists of more than one workspace (a new tab cancels and re-reads all of them): \(wide)")
    }
}
