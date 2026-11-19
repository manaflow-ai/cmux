import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// What a New Tab page costs in listings of the Commands palette's actions (``AgentPaneNewTabActions``).
///
/// The page's bar lists every action the palette could run. One listing reads the state of each catalog action,
/// a slice in each display frame, so a page has no command row for some hundred frames. The list depends on what
/// is focused and on the registry, not on the page: a page that shows while the last list still holds needs no
/// read at all. These rows hold that by counts (``AgentPaneNewTabActions/Counts``), never by a clock: the row
/// fires each display frame itself.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct NewTabCommandListKeptTests {
    private typealias Listed = AgentPaneNewTabActions.Listed

    /// A second page, with the same kind of focus and no change of the registry since the first one's list, has
    /// the palette's actions in the turn that shows it, and no catalog action is read again for it.
    @Test func aSecondPageHasThePalettesActionsWhenItShowsWithNoNewRead() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let lister = app.services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(app.services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        try #require(!list.actions.isEmpty && first.page.omnibar.actions == list.actions, "the first page did not get the list")
        let before = lister.counts
        Self.report("the first page's listing", before, frames: cold.frames, of: list, in: app.services)

        let second = try Self.openPage(app)
        #expect(second.page.omnibar.actions == list.actions,
                "the second page shows with \(second.page.omnibar.actions.count) of the \(list.actions.count) actions")
        // The page's own ask (its hook two frames after it shows, or the first keystroke), then the row's.
        second.loadPaletteActions()
        let again = await Self.listed(app.services)
        let after = lister.counts
        print("new-tab-list: the second page: \(after.started - before.started) listings started, "
            + "\(after.actionsRead - before.actionsRead) catalog actions read again in \(again.frames) frames with a lister task")
        #expect(after.started == before.started, "the second page started \(after.started - before.started) more listings")
        #expect(after.actionsRead == before.actionsRead,
                "the second page read \(after.actionsRead - before.actionsRead) catalog actions again, in \(again.frames) frames with a lister task")
    }

    /// A request that comes after a listing's last slice and before its hand-over joins that list: the finished
    /// list is not dropped, and no new read starts.
    @Test func aRequestBeforeTheHandOverKeepsTheFinishedList() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let page = try Self.openPage(app)
        let start = lister.counts
        page.loadPaletteActions()
        // The row is the display. No turn of the main thread ends between these frames, and the hand-over needs
        // one (the list's JSON is made off the main thread), so it cannot come before the second request.
        // The lister adds a listing's actions to its count in the task that reads the last of them.
        let limit = Self.frameLimit(services)
        var fired = 0
        while lister.counts.actionsRead == start.actionsRead, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let read = lister.counts
        try #require(read.actionsRead > start.actionsRead, "no listing was read to its end in \(fired) frames: \(read)")
        try #require(page.page.omnibar.actions.isEmpty, "the list was handed over in the frame of its last slice")

        let asked = await Self.listed(services)
        let list = try #require(asked.list, "the second request never got a list")
        let end = lister.counts
        print("new-tab-list: a request before the hand-over: \(end.started - start.started) listings started, "
            + "\(end.dropped - start.dropped) lists dropped, \(end.actionsRead - read.actionsRead) catalog actions read again")
        #expect(page.page.omnibar.actions == list.actions, "the page and the second request did not get one list")
        #expect(end.dropped == start.dropped, "a request before the hand-over dropped \(end.dropped - start.dropped) finished lists")
        #expect(end.started == read.started,
                "a request before the hand-over started \(end.started - read.started) more listings (\(end.actionsRead - read.actionsRead) catalog actions read again)")
    }

    /// A hold of the New Tab key after a list was read: each of its ten pages shows with the palette's actions, and
    /// the hold starts no listing.
    @Test func aHoldOfTenPagesStartsNoListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let before = lister.counts

        var without = 0
        for _ in 0..<10 {
            let page = try Self.openPage(app)
            if page.page.omnibar.actions != list.actions { without += 1 }
            // A held key gives a page each 33 ms: two frames at 60 Hz. Then the page asks, as its hook does.
            services.mainWork.frameDidFire()
            services.mainWork.frameDidFire()
            page.loadPaletteActions()
        }
        let held = await Self.listed(services)
        let after = lister.counts
        print("new-tab-list: a hold of 10 pages: \(without) pages showed without the actions, \(after.started - before.started) listings started, "
            + "\(after.dropped - before.dropped) lists dropped, \(after.actionsRead - before.actionsRead) catalog actions read again in \(held.frames) frames with a lister task after the last page")
        #expect(without == 0, "\(without) of the 10 pages showed without the palette's actions")
        #expect(after.started == before.started,
                "the hold started \(after.started - before.started) listings and read \(after.actionsRead - before.actionsRead) catalog actions again")
    }

    // MARK: - The app

    private struct App {
        let services: AppServices
        let pane: PaneController
        let close: @MainActor () -> Void
    }

    /// A window of this Mac with one pane, with the native New Tab page on.
    private static func shown() async throws -> App {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "list-kept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["list-kept-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let close: @MainActor () -> Void = {
            services.newTabSpares.dropAll()
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            // The window's first content comes in a later turn. This wait is the fixture's, not a row's.
            try await PinnedPageTests.until({ controller.workspaceContent?.panes.count == 1 }, report: { "the window never showed the workspace's pane" })
            let content = try #require(controller.workspaceContent)
            content.contentView.layoutSubtreeIfNeeded()
            let window = try #require(controller.window)
            services.newTabSpares.retarget(window)
            let pane = try #require(content.panes.values.first)
            return App(services: services, pane: pane, close: close)
        } catch {
            close()
            throw error
        }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "list-kept-ws"), name: "list", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "list-kept-ws"), index: 0)])
        return tree
    }

    /// Cmd-T with a page prepared: the page shows in the open's own turn. Returns the page's model.
    private static func openPage(_ app: App) throws -> NativeNewTabModel {
        let pool = app.services.newTabSpares
        pool.warmNative()
        let spare = try #require(pool.nativeSpare, "no native New Tab page was prepared")
        let model = try #require(spare.model, "the prepared page has no model")
        let key = try #require(NewTabPage.openNative(in: app.pane, reusingShown: false), "the native New Tab page is off")
        try #require(app.pane.currentTabKey == key, "Cmd-T did not show the prepared page in its own turn")
        return model
    }

    /// What one ask gave: the list (nil when no hand-over came), and the frames the lister had a task for.
    private struct Asked {
        var list: Listed?
        var frames: Int
    }

    /// The lister's frame queue, as the frame scheduler names its clients.
    private static let lister = "NewTab.paletteActions"

    /// The most frames with a lister task that a row fires for one ask. A listing reads one catalog action or more
    /// in each task, so it has at most as many tasks as the catalog has entries, and one to start, one to arrange
    /// and one to hand over. Four times that is far above any listing (ten times the largest cold listing of the
    /// runs so far, 315 tasks, at the least).
    private static func frameLimit(_ services: AppServices) -> Int {
        max(4 * (services.registry.entries.count + 3), 3150)
    }

    /// Asks for the list as a page does, and is the display until the lister hands it over: one frame after
    /// another, with no clock. No hand-over in ``frameLimit(_:)`` frames with a lister task is an issue.
    private static func listed(_ services: AppServices) async -> Asked {
        let (lists, feed) = AsyncStream.makeStream(of: Listed.self)
        services.newTabActions.list(wanted: { true }) { list in
            feed.yield(list)
            feed.finish()
        }
        let limit = frameLimit(services)
        // The row's display link: it ends only when the row cancels it.
        let frames = Task { @MainActor () -> Int in
            var working = 0
            while !Task.isCancelled {
                // Only a frame the lister has a task for counts. While the list's JSON is made off the main thread
                // the lister has none, and how many frames pass then is a matter of time, not of the listing.
                if services.mainWork.frames.activeClients.contains(lister) {
                    working += 1
                    if working == limit + 1 { feed.finish() }
                }
                services.mainWork.frameDidFire()
                // The JSON's hop back to the main thread runs here.
                await Task.yield()
            }
            return working
        }
        var got: Listed?
        for await list in lists { got = list }
        frames.cancel()
        let working = await frames.value
        if got == nil {
            let counts = services.newTabActions.counts
            Issue.record("no hand-over in \(working) frames with a lister task (the limit is \(limit)); listings started = \(counts.started), lists dropped = \(counts.dropped)")
        }
        return Asked(list: got, frames: working)
    }

    /// Prints what one listing cost and what the catalog's rules read, for the record of a run.
    private static func report(_ what: String, _ counts: AgentPaneNewTabActions.Counts, frames: Int, of list: Listed, in services: AppServices) {
        let entries = services.registry.entries
        func bound(_ has: (CmuxNextActions.Action) -> Bool) -> Int { entries.filter { $0.action.map(has) ?? false }.count }
        let state = bound { $0.paletteState != nil }
        let title = bound { $0.paletteTitle != nil }
        let reason = bound { $0.paletteUnavailableReason != nil }
        let handler = bound { $0.unavailableReason != nil }
        let withRule = bound { $0.paletteState != nil || $0.paletteTitle != nil || $0.paletteUnavailableReason != nil || $0.unavailableReason != nil }
        let rules = "a palette state \(state), a palette title \(title), a palette reason \(reason), a reason of its handler \(handler), one or more of these \(withRule)"
        print("new-tab-list: \(what): \(counts.started) listings started, \(frames) frames with a lister task, \(counts.actionsRead) catalog actions read; "
            + "the catalog has \(entries.count) entries, \(entries.filter(\.isBound).count) with a handler; "
            + "the list has \(list.actions.count) rows in \(list.json.utf8.count) bytes of JSON; "
            + "actions with a rule that reads a state: \(rules)")
    }
}
