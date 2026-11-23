import AppKit
@testable import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTabs
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
///
/// Each row prints its frames (the lines `new-tab-list:`) and what the lister's tasks cost in them (the lines
/// `new-tab-list-tasks:`, ``printTasks(_:since:in:)``). A listing reads actions for 0.5 ms in each task, so its
/// frames are its time. The second line has the time of a fixed work on the same Mac: a Mac that is slow now makes
/// that time and the frames larger, and a read that costs more makes only the frames larger.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .closesItsWindows)
struct NewTabCommandListKeptTests {
    typealias Listed = AgentPaneNewTabActions.Listed

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
    /// list is handed over as it is, and no new read starts.
    @Test func aRequestBeforeTheHandOverKeepsTheFinishedList() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let page = try Self.openPage(app)
        let start = lister.counts
        let cost = Self.tasks(services)
        page.loadPaletteActions()
        // The row is the display. No turn of the main thread ends between these frames, and the hand-over needs one (the
        // list's JSON is made off the main thread). The count rises in the task that reads the last action.
        let limit = Self.frameLimit(services)
        var fired = 0
        while lister.counts.actionsRead == start.actionsRead, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let read = lister.counts
        // The line of these tasks has the fixed work, so it prints at the row's end, after each check of the row.
        let slices = Spent("\(#function): a listing to its last slice, \(fired) frames of the row", since: cost, in: services)
        defer { slices.printLine() }
        try #require(read.actionsRead > start.actionsRead, "no listing was read to its end in \(fired) frames: \(read)")
        try #require(page.page.omnibar.actions.isEmpty, "the list was handed over in the frame of its last slice")

        // The second request. No turn of the main thread ends between it and these frames, so no hand-over comes in
        // them: a request that did not join has its first task there, and that task can only start a second listing.
        let waiter = Self.ask(services)
        var more = 0
        // The frames of these in which the count of listings rose: a red names its order by them.
        var rose: [Int] = []
        while services.mainWork.frames.activeClients.contains(Self.lister), more < limit {
            let count = lister.counts.started
            services.mainWork.frameDidFire()
            more += 1
            if lister.counts.started != count { rose.append(more) }
        }
        let joined = lister.counts
        let order = "the second request started \(joined.started - read.started) listings before the hand-over: the row fired \(more) frames with a lister task, "
            + "the count of listings was \(read.started) before them, rose in the frames \(rose), and was \(joined.started) after the last"
        #expect(joined.started == read.started, "\(order)")
        let asked = await Self.handOver(to: waiter, services)
        let list = try #require(asked.list, "the second request never got a list")
        let end = lister.counts
        print("new-tab-list: a request before the hand-over: \(end.started - start.started) listings started, \(more) frames of the row before the hand-over, "
            + "\(end.actionsRead - read.actionsRead) catalog actions read again")
        #expect(page.page.omnibar.actions == list.actions, "the page and the second request did not get one list")
        #expect(end.started == read.started,
                "a request before the hand-over started \(end.started - read.started) more listings (\(end.actionsRead - read.actionsRead) catalog actions read again)")
    }

    /// A hold of the New Tab key after a list was read: each of its ten pages shows with the actions, and starts no listing.
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
            + "\(after.actionsRead - before.actionsRead) catalog actions read again in \(held.frames) frames with a lister task after the last page")
        #expect(without == 0, "\(without) of the 10 pages showed without the palette's actions")
        #expect(after.started == before.started,
                "the hold started \(after.started - before.started) listings and read \(after.actionsRead - before.actionsRead) catalog actions again")
    }

    /// What a hold of the New Tab key did, as its driver saw it.
    @MainActor private final class Hold {
        var pages: [NativeNewTabModel] = []
        var asks = 0
        /// Frames the lister had a task for.
        var frames = 0
        /// The lister's counts in the turn of the hand-over.
        var handed: AgentPaneNewTabActions.Counts?
        var failure: String?
    }

    /// A hold of the New Tab key in a window that has no list yet, for as long as the listing takes: an ask each two frames
    /// from the first frame until the hand-over (the first ten are pages). One listing serves them all: each page has its list.
    @Test func aHoldWithNoListYetIsOneListing() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let start = lister.counts
        let cost = Self.tasks(services)
        let limit = Self.frameLimit(services)
        let hold = Hold()
        let (lists, feed) = AsyncStream.makeStream(of: Listed.self)
        // The held key and the display in one: it ends only when the row cancels it.
        let key = Task { @MainActor in
            while !Task.isCancelled {
                if hold.handed == nil, hold.failure == nil {
                    if hold.pages.count < 10 {
                        do {
                            let page = try Self.openPage(app)
                            page.loadPaletteActions()
                            hold.pages.append(page)
                        } catch {
                            hold.failure = "page \(hold.pages.count + 1) of the hold did not open: \(error)"
                            feed.finish()
                        }
                    }
                    // The row's ask, as a page's: every waiter gets the list in the turn of the hand-over.
                    lister.list(wanted: { true }) { list in
                        guard hold.handed == nil else { return }
                        hold.handed = lister.counts
                        feed.yield(list)
                        feed.finish()
                    }
                    hold.asks += 1
                }
                // A held key gives a page each 33 ms: two frames at 60 Hz. No turn of the main thread ends between
                // an ask and its two frames; one ends after them (the list's JSON comes back to the main thread there).
                for _ in 0..<2 {
                    if services.mainWork.frames.activeClients.contains(Self.lister) {
                        hold.frames += 1
                        if hold.frames == limit + 1 {
                            hold.failure = "no hand-over in \(limit) frames with a lister task"
                            feed.finish()
                        }
                    }
                    services.mainWork.frameDidFire()
                }
                await Task.yield()
            }
        }
        var got: Listed?
        for await list in lists { got = list }
        key.cancel()
        await key.value
        let now = lister.counts
        let end = hold.handed ?? now
        print("new-tab-list: a hold with no list yet: \(hold.asks) asks, one each 2 frames, until the hand-over; "
            + "\(end.started - start.started) listings started, "
            + "\(end.actionsRead - start.actionsRead) catalog actions read, \(hold.frames) frames with a lister task")
        Self.printTasks("\(#function): a hold to its hand-over, \(hold.frames) frames with a lister task", since: cost, in: services)
        let list = try #require(got, "\(hold.failure ?? "no hand-over"); \(hold.asks) asks; listings started = \(now.started - start.started)")
        let without = hold.pages.filter { $0.page.omnibar.actions != list.actions }.count
        #expect(end.started == start.started + 1, "the hold started \(end.started - start.started) listings in \(hold.asks) asks")
        #expect(without == 0, "\(without) of the hold's \(hold.pages.count) pages do not have the list after its hand-over")
    }

    /// The first letter in a page that showed with the kept list reads the actions again, and never in its own turn: that
    /// turn reads no action and only queues the listing's first task. A second letter while it runs starts no second one.
    @Test func theFirstLetterReadsTheActionsAgainInLaterFrames() async throws {
        let app = try await Self.shown()
        defer { app.close() }
        let services = app.services
        let lister = services.newTabActions
        let first = try Self.openPage(app)
        first.loadPaletteActions()
        let cold = await Self.listed(services)
        let list = try #require(cold.list, "the first page's listing never handed its list over")
        let page = try Self.openPage(app)
        try #require(page.page.omnibar.actions == list.actions, "the second page did not show with the kept list")
        let before = lister.counts

        page.text = "a"
        let typed = lister.counts
        #expect(typed == before, "the first letter's turn started \(typed.started - before.started) listings and read \(typed.actionsRead - before.actionsRead) catalog actions")
        #expect(services.mainWork.frames.activeClients.contains(Self.lister), "the first letter queued no task of the lister")

        // The row is the display: the listing's first task runs in one of these frames, never in the letter's turn.
        let limit = Self.frameLimit(services)
        var fired = 0
        while lister.counts.started == before.started, fired < limit {
            services.mainWork.frameDidFire()
            fired += 1
        }
        let running = lister.counts
        try #require(running.started == before.started + 1, "the first letter started no listing in \(fired) frames")
        try #require(running.actionsRead == before.actionsRead, "the listing ended in its first task")
        // A second letter while the listing runs.
        page.text = "ab"
        let again = await Self.listed(services)
        let end = lister.counts
        // A third letter: the page's own listing read its list, so it asks for nothing more.
        page.text = "abc"
        let third = await Self.listed(services)
        let last = lister.counts
        print("new-tab-list: the first letter in a page with the kept list: \(typed.started - before.started) listings started and "
            + "\(typed.actionsRead - before.actionsRead) catalog actions read in its turn, the listing's first task \(fired) frames later; "
            + "\(end.started - before.started) listings started and \(end.actionsRead - before.actionsRead) catalog actions read to the hand-over, "
            + "\(again.frames) frames with a lister task after the second letter; a third letter: \(last.started - end.started) listings started")
        #expect(again.list != nil && third.list != nil)
        #expect(end.started == before.started + 1, "two letters started \(end.started - before.started) listings")
        #expect(end.actionsRead > before.actionsRead, "the first letter's listing read no catalog action")
        #expect(last.started == end.started, "a third letter started \(last.started - end.started) more listings")
    }

    // MARK: - The app

    @MainActor struct App {
        let services: AppServices
        let pane: PaneController
        let close: @MainActor () -> Void
    }

    /// A window of this Mac with one pane, with the native New Tab page on.
    static func shown() async throws -> App {
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
    static func openPage(_ app: App) throws -> NativeNewTabModel {
        let pool = app.services.newTabSpares
        pool.warmNative()
        let spare = try #require(pool.nativeSpare, "no native New Tab page was prepared")
        let model = try #require(spare.model, "the prepared page has no model")
        let key = try #require(NewTabPage.openNative(in: app.pane, reusingShown: false), "the native New Tab page is off")
        try #require(app.pane.currentTabKey == key, "Cmd-T did not show the prepared page in its own turn")
        return model
    }

    /// What one ask gave: the list (nil when no hand-over came), the frames the lister had a task for, and the
    /// lister's tasks from the ask to its hand-over.
    struct Asked {
        var list: Listed?
        var frames: Int
        var tasks: Spent
    }

    /// The lister's frame queue, as the frame scheduler names its clients.
    static let lister = "NewTab.paletteActions"

    /// The most frames with a lister task that a row fires for one ask. A listing reads one catalog action or more in
    /// each task: at most one task for each entry and 3 more. Four times that is ten times the largest listing so far.
    static func frameLimit(_ services: AppServices) -> Int {
        max(4 * (services.registry.entries.count + 3), 3150)
    }

    /// One waiter of the lister, as a page is one: its stream gets the list at the hand-over.
    typealias Waiter = (lists: AsyncStream<Listed>, feed: AsyncStream<Listed>.Continuation)

    /// Asks for the list as a page does.
    static func ask(_ services: AppServices) -> Waiter {
        let (lists, feed) = AsyncStream.makeStream(of: Listed.self)
        services.newTabActions.list(wanted: { true }) { list in
            feed.yield(list)
            feed.finish()
        }
        return (lists, feed)
    }

    /// Asks for the list as a page does, and is the display until the lister hands it over. `row` is the name in the
    /// printed line of the lister's tasks: the function that asks. `prints`: see ``handOver(to:_:row:prints:inFrame:)``.
    static func listed(_ services: AppServices, row: String = #function, prints: Bool = true,
                       inFrame: @escaping @MainActor @Sendable () -> Void = {}) async -> Asked {
        await handOver(to: ask(services), services, row: row, prints: prints, inFrame: inFrame)
    }

    /// Is the display until the lister hands the list to `waiter`: one frame after another, with no clock. No hand-over
    /// in ``frameLimit(_:)`` frames with a lister task is an issue. `inFrame` runs before each of those frames. Prints
    /// its frames and what the lister's tasks cost in them (``Spent/printLine()``), under the name `row`. That line
    /// has the fixed work: a row that measures a time to after its ask gives `prints` false and prints
    /// ``Asked/tasks`` itself, after it read its values.
    static func handOver(to waiter: Waiter, _ services: AppServices, row: String = #function, prints: Bool = true,
                         inFrame: @escaping @MainActor @Sendable () -> Void = {}) async -> Asked {
        let (lists, feed) = waiter
        let limit = frameLimit(services)
        let cost = tasks(services)
        // The row's display link: it ends only when the row cancels it.
        let frames = Task { @MainActor () -> Int in
            var working = 0
            while !Task.isCancelled {
                // Only a frame the lister has a task for counts. While the list's JSON is made off the main thread
                // the lister has none, and how many frames pass then is a matter of time, not of the listing.
                if services.mainWork.frames.activeClients.contains(lister) {
                    working += 1
                    if working == limit + 1 { feed.finish() }
                    inFrame()
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
            Issue.record("no hand-over in \(working) frames with a lister task (the limit is \(limit)); listings started = \(counts.started)")
        }
        let spent = Spent("\(row): an ask to its hand-over, \(working) frames with a lister task", since: cost, in: services)
        if prints { spent.printLine() }
        return Asked(list: got, frames: working, tasks: spent)
    }

    /// The lister at one moment: its counts, and its tasks in the always-on record of the main thread's budget
    /// (`MainFrameBudget.ownerTimes`: how many ran, and their own time). For a print, never for a row's verdict.
    struct Tasks {
        var counts: AgentPaneNewTabActions.Counts
        var ran: Int
        var nanos: UInt64
        /// The median and the longest of the lister's tasks since the app's start, in microseconds.
        var median: UInt64
        var longest: UInt64
    }

    static func tasks(_ services: AppServices) -> Tasks {
        let name = lister
        let times = services.mainWork.budget.ownerTimes.first { $0.owner == name }
        return Tasks(counts: services.newTabActions.counts, ran: times?.count ?? 0, nanos: times?.totalNanos ?? 0,
                     median: (times?.p50Nanos ?? 0) / 1000, longest: (times?.maxNanos ?? 0) / 1000)
    }

    /// The steps of ``fixedWork()``.
    static let fixedSteps: UInt64 = 200_000

    /// The time of one fixed piece of work on this Mac now, in microseconds (the least of 3 runs of the same
    /// arithmetic), and the sum that the 3 runs made. It reads nothing of the app. A Mac that is slow or busy now
    /// takes longer for it, and a change of the app's code does not. The sum is the same number in each run, and the
    /// line prints it: a build with optimization must do the work to have it.
    static func fixedWork() -> (micros: Int64, sum: UInt64) {
        let clock = ContinuousClock(), steps = fixedSteps
        var least = Duration.seconds(3600)
        var sum: UInt64 = 1
        for _ in 0..<3 {
            let took: Duration = clock.measure {
                var step: UInt64 = 0
                while step < steps {
                    sum = sum &* 6_364_136_223_846_793_005 &+ step
                    step += 1
                }
            }
            if took < least { least = took }
        }
        let (seconds, attoseconds) = least.components
        return (seconds * 1_000_000 + attoseconds / 1_000_000_000_000, sum)
    }

    /// The lister's tasks in one span of a row, from `before` to the span's end (the values are read at the make).
    /// Its line prints apart (``printLine()``): the line has the fixed work, and that runs in no measured part of a
    /// row, only after the row read its own values.
    @MainActor struct Spent {
        var what: String
        var before: Tasks
        var now: Tasks

        init(_ what: String, since before: Tasks, in services: AppServices) {
            self.what = what
            self.before = before
            now = NewTabCommandListKeptTests.tasks(services)
        }

        /// Prints what the lister's tasks cost in the span, for the record of a run. A listing's task reads actions
        /// until 0.5 ms after its start (``AgentPaneNewTabActions/slice``), so each task's time says little and the
        /// frames of a listing are its time. What a later read can part with this line: the actions that one task
        /// read are fewer on a Mac that is slow now AND after a change that makes a read cost more; the fixed work is
        /// slower only on the Mac that is slow now. The line of a span that read no action to its end has no fixed
        /// work.
        func printLine() {
            let ran: Int = max(now.ran - before.ran, 0)
            let micros: UInt64 = (now.nanos >= before.nanos ? now.nanos - before.nanos : 0) / 1000
            let each: UInt64 = ran > 0 ? micros / UInt64(ran) : 0
            let started: Int = now.counts.started - before.counts.started
            let read: Int = max(now.counts.actionsRead - before.counts.actionsRead, 0)
            var line = "new-tab-list-tasks: \(what): \(ran) tasks of the lister in the main thread's record, \(micros) microseconds of own time, "
            line += "\(each) for each task (a task's reads end 500 microseconds after their start); since the app's start the median task took "
            line += "\(now.median) microseconds and the longest \(now.longest); \(started) listings started, \(read) catalog actions read"
            if read > 0, ran > 0, micros > 0 {
                let inATask: Int = read / ran
                let inAMillisecond: UInt64 = UInt64(read) * 1000 / micros
                let fixed = NewTabCommandListKeptTests.fixedWork()
                line += ", \(inATask) for each task and \(inAMillisecond) for each millisecond of the tasks; the fixed work of "
                line += "\(NewTabCommandListKeptTests.fixedSteps) steps took \(fixed.micros) microseconds on this Mac now (its sum is \(fixed.sum))"
            }
            print(line)
        }
    }

    /// Prints the line of the lister's tasks from `before` to now (``Spent``).
    static func printTasks(_ what: String, since before: Tasks, in services: AppServices) {
        Spent(what, since: before, in: services).printLine()
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
