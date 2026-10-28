import AppKit
@testable import CmuxNextApp
import CmuxNextBookmarks
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextApp/{Bookmarks,History} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-316,
/// rule 9): closed history retention reads only the machines whose closed list revision moved (all when the limits
/// change), Chromium bookmark sync runs in idle time after its settle and drops a stale one, a superseded home switch's
/// steps do nothing, a hidden tab's bookmarks bar reloads once on show, and the home daemon follower (a migrated
/// `ServiceObservation`) applies a person's change before the commit and yields an automation change to pending input.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BookmarksHistorySchedulerSweepTests {
    // MARK: Closed history retention (R-index)

    @Test func retentionChecksOnlyTheMachinesWhoseClosedRevisionMoved() {
        let limits = ClosedRetention(maxGroups: 50, maxAgeDays: 30)
        var checks = ClosedRetentionChecks()
        #expect(checks.advance(limits: limits, machines: ["local": 1, "vm": 4]) == ["local", "vm"], "the first state checks every machine")
        #expect(checks.advance(limits: limits, machines: ["local": 1, "vm": 4]).isEmpty, "nothing moved: nothing is read")
        #expect(checks.advance(limits: limits, machines: ["local": 2, "vm": 4]) == ["local"], "a bump of one machine read the others")
        #expect(checks.advance(limits: limits, machines: ["local": 2, "vm": 4, "mini": 0]) == ["mini"], "a machine that connected is checked")
        #expect(checks.advance(limits: limits, machines: ["local": 2, "mini": 0]).isEmpty, "a machine that left is no check")
        #expect(checks.advance(limits: limits, machines: ["local": 2, "vm": 4, "mini": 0]) == ["vm"], "a machine back again is checked")
    }

    @Test func retentionChecksEveryMachineWhenTheLimitsChange() {
        var checks = ClosedRetentionChecks()
        _ = checks.advance(limits: ClosedRetention(maxGroups: 50, maxAgeDays: 30), machines: ["local": 1, "vm": 4])
        let tighter = ClosedRetention(maxGroups: 10, maxAgeDays: 30)
        #expect(checks.advance(limits: tighter, machines: ["local": 1, "vm": 4]) == ["local", "vm"])
        #expect(checks.limits == tighter)
        #expect(checks.advance(limits: tighter, machines: ["local": 1, "vm": 4]).isEmpty)
    }

    // MARK: Chromium bookmark sync (R-timer, idle work)

    @Test func aSettledSyncRunsAsAnIdleTaskWithItsMaxDelay() {
        let rig = MainDeadlineRig(), idle = IdlePosts()
        let settle = BookmarkSyncSettle(settle: .milliseconds(400), maxDelay: .seconds(2), deadlines: rig.deadlines, postIdle: idle.post)
        var syncs = 0
        settle.schedule("store-1") { syncs += 1 }
        settle.schedule("store-1") { syncs += 1 }
        #expect(idle.posts.isEmpty, "a sync was posted before its settle")
        rig.fireAndRun()
        #expect(rig.elapsed >= 0.4, "the settle fired \(rig.elapsed) s in, before its 0.4 s")
        #expect(idle.posts.map(\.owner) == ["BookmarkChromiumSync.sync"], "two events in one settle posted \(idle.posts.count) syncs")
        #expect(idle.posts.first?.maxDelay == .seconds(2), "a settled sync must still run by its max delay on a busy main thread")
        #expect(syncs == 0, "the sync ran outside idle time")
        idle.runIdle()
        #expect(syncs == 1)
        #expect(!rig.hasArmedWake)
    }

    @Test func aSettleRestartedAfterItsIdlePostDropsTheEarlierSync() {
        let rig = MainDeadlineRig(), idle = IdlePosts()
        let settle = BookmarkSyncSettle(settle: .milliseconds(400), maxDelay: .seconds(2), deadlines: rig.deadlines, postIdle: idle.post)
        var synced: [String] = []
        settle.schedule("store-1") { synced.append("first") }
        rig.fireAndRun()
        #expect(idle.posts.count == 1)
        // Chromium's next event: the settle starts again before the idle task ran.
        settle.schedule("store-1") { synced.append("second") }
        idle.runIdle()
        #expect(synced.isEmpty, "the stale sync ran while the store's events were still coming")
        rig.fireAndRun()
        idle.runIdle()
        #expect(synced == ["second"])
    }

    // MARK: Home daemon switch (R-hop chain)

    /// A flip during the copy: the replaced switch neither settles the home nor waits for its reads, so the next
    /// switch runs at once.
    @Test func aFlipDuringTheCopyMakesTheStaleSwitchStepsDoNothing() throws {
        _ = NSApplication.shared
        let fixture = SweepScheduler()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: fixture.work)
        let bookmarks = services.bookmarks, gate = HomeCopyGate(holds: true)
        bookmarks.homeCopy = { await gate.copy() }
        bookmarks.switchHome(serves: true)
        fixture.spin(until: { gate.copies == 1 })
        #expect(gate.copies == 1, "the switch did not reach its copy")
        // A read in flight that never answers: a stale switch that settled would wait for it.
        let read = Task { await gate.holdRead() }
        bookmarks.fetching["held"] = read
        bookmarks.fileTrees = ["default": [try Self.bookmark()]]
        bookmarks.fileLoaded = true
        bookmarks.switchHome(serves: false)
        gate.releaseCopy()
        fixture.spin(until: { bookmarks.trees["default"] != nil })
        #expect(bookmarks.trees["default"] != nil, "the switch to the file waited behind the replaced switch")
        #expect(!bookmarks.homeSettled, "the replaced switch settled the home after the flip")
        #expect(gate.copies == 1)
        gate.releaseRead()
        withExtendedLifetime(services) {}
    }

    /// A flip before the first step: the replaced switch's reset does nothing (it would put the file's trees back).
    @Test func aFlipBeforeTheResetMakesTheReplacedResetDoNothing() throws {
        _ = NSApplication.shared
        let fixture = SweepScheduler()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: fixture.work)
        let bookmarks = services.bookmarks, gate = HomeCopyGate(holds: false)
        bookmarks.homeCopy = { await gate.copy() }
        bookmarks.fileTrees = ["default": [try Self.bookmark()]]
        bookmarks.fileLoaded = true
        bookmarks.switchHome(serves: false)
        bookmarks.switchHome(serves: true)
        fixture.spin(until: { bookmarks.homeSettled })
        #expect(bookmarks.homeSettled, "the current switch did not settle")
        #expect(bookmarks.trees["default"] == nil, "the replaced switch put the file's trees back")
        #expect(gate.copies == 1)
        withExtendedLifetime(services) {}
    }

    // MARK: Bookmarks bar (rule 4: hidden = model only)

    @Test func aHiddenTabsBarReloadsOnceOnShow() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let bookmarks = services.bookmarks
        bookmarks.showsBar = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let bar = BookmarksBarView(), builds = CountingBarSource()
        window.contentView?.addSubview(bar)
        bar.source = builds
        let tab = VisibilityNode(root: "test.tab", own: .hidden)
        let entry = BrowserEntry(tab: WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab(), mainWork: services.mainWork, node: nil)
        let chrome = BookmarkService.WeakChrome(entry: entry, bar: bar,
                                                source: BookmarkBarSourceAdapter(service: bookmarks, tabKey: "test.tab"), node: tab)
        let start = builds.count
        bookmarks.reloadBar(chrome)
        bookmarks.reloadBar(chrome)
        #expect(builds.count == start, "a hidden tab's bar reloaded")
        tab.set(.visible)
        #expect(builds.count == start + 1, "the hidden bar did not reload exactly once on show")
        bookmarks.reloadBar(chrome)
        #expect(builds.count == start + 2, "a shown bar did not reload at once")
        withExtendedLifetime((services, window, entry)) {}
    }

    // MARK: Causes on a migrated service owner (BookmarkService.home)

    @Test func aPersonCausedChangeAppliesInTheInputResponsePass() throws {
        _ = NSApplication.shared
        let fixture = SweepScheduler()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: fixture.work)
        let bookmarks = services.bookmarks, store = services.machines.local.store, identity = try Self.identity()
        bookmarks.observeHome()
        let start = bookmarks.homeGeneration
        fixture.input.pending = true
        fixture.work.causes.withCause(.person) { _ = store.apply(.connected(identity, generationChanged: false)) }
        #expect(fixture.work.causes.flushPersonCaused() >= 1)
        #expect(bookmarks.homeGeneration == start &+ 1, "the person's change waited for a frame")
        fixture.input.pending = false
        fixture.spin(until: { bookmarks.homeSettled })
        withExtendedLifetime(services) {}
    }

    @Test func anAutomationChangeYieldsToPendingInputForOneFrame() throws {
        _ = NSApplication.shared
        let fixture = SweepScheduler()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: fixture.work)
        let bookmarks = services.bookmarks, store = services.machines.local.store, identity = try Self.identity()
        bookmarks.observeHome()
        let start = bookmarks.homeGeneration
        fixture.input.pending = true
        fixture.work.causes.withCause(.automation) { _ = store.apply(.connected(identity, generationChanged: false)) }
        #expect(fixture.work.causes.personPendingCount == 0)
        #expect(bookmarks.homeGeneration == start, "an automation change applied in its own turn")
        fixture.frame()
        #expect(bookmarks.homeGeneration == start, "the automation flush ran ahead of the person's pending key")
        fixture.frame()
        #expect(bookmarks.homeGeneration == start &+ 1, "held one frame, never two")
        fixture.input.pending = false
        fixture.spin(until: { bookmarks.homeSettled })
        withExtendedLifetime(services) {}
    }

    // MARK: Helpers

    /// A home daemon handshake that serves bookmarks.
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"bookmarks-sweep-test","generation":"g1","capabilities":["\#(DaemonCapability.bookmarks.rawValue)"]}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func bookmark() throws -> BookmarkNode {
        .bookmark("Example", url: try #require(URL(string: "https://example.com")), in: BookmarkRoot.bar.rawValue)
    }
}

/// The idle tasks posted, run by hand: one call is one idle period.
@MainActor
private final class IdlePosts {
    private(set) var posts: [(owner: String, maxDelay: Duration, body: @MainActor () -> Void)] = []

    var post: BookmarkSyncSettle.PostIdle {
        { [unowned self] owner, maxDelay, body in posts.append((owner, maxDelay, body)) }
    }

    func runIdle() {
        let due = posts
        posts = []
        for post in due { post.body() }
    }
}

/// The switch's copy step, held until the test releases it, and a read that never answers until released.
@MainActor
private final class HomeCopyGate {
    let holds: Bool
    private(set) var copies = 0
    private var copyWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    init(holds: Bool) {
        self.holds = holds
    }

    func copy() async {
        copies += 1
        guard holds else { return }
        await withCheckedContinuation { copyWaiter = $0 }
    }

    func releaseCopy() {
        copyWaiter?.resume()
        copyWaiter = nil
    }

    func holdRead() async {
        await withCheckedContinuation { readWaiter = $0 }
    }

    func releaseRead() {
        readWaiter?.resume()
        readWaiter = nil
    }
}

/// Counts the bar's builds (each reload in a window reads the bar's children once).
@MainActor
private final class CountingBarSource: BookmarksBarSource {
    private(set) var count = 0
    func bookmarkChildren(of parent: String) -> [BookmarkNode] {
        if parent == BookmarkRoot.bar.rawValue { count += 1 }
        return []
    }

    func favicon(for node: BookmarkNode) -> NSImage? { nil }
    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition) {}
    func openAll(in folder: String) {}
    func moveToBar(_ id: String, index: Int) {}
    func addToBar(url: URL, title: String, index: Int) {}
    func contextMenu(for node: BookmarkNode?) -> NSMenu? { nil }
}

/// The app's scheduler on a fake link, a clock the test moves and an input source it sets; frames are fired by hand.
@MainActor
private final class SweepScheduler {
    let input: SweepInput
    let work: MainWorkScheduler
    private let clock: BookmarksSweepClock
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = SweepInput(), clock = BookmarksSweepClock()
        self.input = input
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in SweepLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Main run loop passes (where off-main posts arrive) and frames, until `done` or 5 s.
    func spin(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            frame()
        }
    }
}

@MainActor
private final class BookmarksSweepClock {
    var now: UInt64 = 1_000_000_000
    // Strong: the scheduler's stall timer may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
}

@MainActor
private final class SweepInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class SweepLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
