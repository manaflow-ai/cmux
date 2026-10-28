import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The row feed keeps current only the rows the list shows (feature
/// `sidebarRowsNearViewport`): 400 rows with 30 on screen arm 30 observations, a change of a row off
/// screen maps nothing, a stale row is mapped once when it comes back (in the same turn when it comes
/// on screen), and a row that did not change is never mapped on scroll-in.
@MainActor @Suite struct SidebarRowFeedTests {
    @Observable final class Status {
        var text = "idle"
    }

    /// The scheduled flushes, each with its cause.
    final class Pending {
        var work: [(cause: ObservationCause, run: @MainActor @Sendable () -> Void)] = []
        var causes: [ObservationCause] { work.map(\.cause) }
        func run(only cause: ObservationCause? = nil) {
            while let index = work.firstIndex(where: { cause == nil || $0.cause == cause }) {
                work.remove(at: index).run()
            }
        }
    }

    /// How many times each row was mapped.
    final class Maps {
        var counts: [WorkspaceID: Int] = [:]
        var total: Int { counts.values.reduce(0, +) }
        func reset() { counts.removeAll() }
    }

    /// The rows each flush patched, in order.
    final class Patches {
        var rows: [[SidebarWorkspace]] = []
        var ids: [WorkspaceID] { rows.flatMap { $0 }.map(\.id) }
    }

    /// The cause the next change is made under.
    final class Cause {
        var now = ObservationCause.program
    }

    struct Fixture {
        let feed: SidebarRowFeed
        let ledger: ObservationLedger
        let pending: Pending
        let cause: Cause
        let maps = Maps()
        let patches: Patches
        let ids: [WorkspaceID]
        let status: [WorkspaceID: Status]
        var patched: [[SidebarWorkspace]] { patches.rows }

        init(rows: Int) {
            let ledger = ObservationLedger(), pending = Pending(), patches = Patches(), cause = Cause()
            let feed = SidebarRowFeed(cause: { cause.now }, schedule: { cause, work in pending.work.append((cause, work)) },
                                      observations: ledger.owner("SidebarRows"))
            feed.onChange = { patches.rows.append($0) }
            self.feed = feed
            self.ledger = ledger
            self.pending = pending
            self.cause = cause
            self.patches = patches
            ids = (0..<rows).map { WorkspaceID("w\($0)") }
            status = Dictionary(uniqueKeysWithValues: ids.map { ($0, Status()) })
        }

        /// One structural pass naming `only` (every row by default).
        func pass(inputs: Int = 0, only: [WorkspaceID]? = nil) {
            feed.beginPass(inputs: inputs)
            let rows = (only ?? ids).map { id in
                feed.row(id, machine: .local) { [status, maps] in
                    maps.counts[id, default: 0] += 1
                    return SidebarWorkspace(id: id, machineID: .local, title: "\(id.rawValue) \(inputs)",
                                            status: status[id]?.text ?? "")
                }
            }
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            _ = feed.fill([SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })])
        }

        /// Writes `id`'s status, as a daemon event does.
        func set(_ id: WorkspaceID, _ text: String) {
            if let source = status[id] { source.text = text }
        }

        /// The ids of rows `range`.
        func rows(_ range: Range<Int>) -> Set<WorkspaceID> { Set(ids[range]) }

        /// Rows `visible` on screen, and half a screen of overscan each way.
        func screen(_ visible: Range<Int>, rollUp: Range<Int>? = nil) -> SidebarRowFeed.Viewport {
            let half = visible.count / 2
            let near = max(0, visible.lowerBound - half)..<min(ids.count, visible.upperBound + half)
            return SidebarRowFeed.Viewport(visible: rows(visible), near: rows(near), rollUp: rollUp.map { rows($0) } ?? [])
        }

        func snapshot() throws -> ObservationLedger.Entry {
            try #require(ledger.snapshot(resetting: true).first)
        }
    }

    /// 400 rows, rows 0..<30 on screen and half a screen past them (0..<45 near).
    static func scrolledToTop() throws -> Fixture {
        let fixture = Fixture(rows: 400)
        fixture.pass()
        fixture.feed.watch(drawn: Set(fixture.ids), fixture.screen(0..<30))
        fixture.pending.run()
        fixture.maps.reset()
        _ = try fixture.snapshot()
        return fixture
    }

    @Test func onlyTheRowsOnScreenStayArmed() throws {
        let fixture = Fixture(rows: 400)
        fixture.pass()
        #expect(try fixture.snapshot().armed == 400, "without a list every row is armed")

        fixture.feed.watch(drawn: Set(fixture.ids), fixture.screen(200..<230))
        fixture.pending.run()
        let entry = try fixture.snapshot()
        #expect(entry.armed <= 60)
        #expect(entry.armed == 30, "the overscan is followed, not armed")
        #expect(entry.evaluations == 0, "the rows on screen were current: nothing is mapped again")
    }

    @Test func aChangeOffScreenMapsNothing() throws {
        let fixture = try Self.scrolledToTop()
        fixture.set(fixture.ids[300], "running")
        fixture.set(fixture.ids[40], "running") // in the overscan
        fixture.pending.run()
        #expect(fixture.maps.total == 0)
        #expect(try fixture.snapshot().evaluations == 0)
        #expect(fixture.patched.isEmpty)
    }

    @Test func aStaleRowScrolledOnScreenIsMappedOnceInTheSameTurn() throws {
        let fixture = try Self.scrolledToTop()
        let away = fixture.ids[300]
        fixture.set(away, "running")
        fixture.pending.run()

        // A jump: the row is on screen in this call, with no flush run yet.
        fixture.feed.watch(fixture.screen(290..<320))
        #expect(fixture.maps.total == 1, "only the row that changed is mapped")
        #expect(fixture.patches.ids == [away])
        #expect(fixture.patched.last?.first?.status == "running")
        #expect(try fixture.snapshot().armed == 30, "the rows that left keep a sentinel, the ones that came are armed")

        fixture.pending.run()
        #expect(fixture.maps.total == 1, "the overscan rows that came did not change: no map")
    }

    @Test func unchangedRowsScrolledIntoViewMapNothing() throws {
        let fixture = try Self.scrolledToTop()
        fixture.feed.watch(fixture.screen(200..<230))
        fixture.pending.run()
        fixture.feed.watch(fixture.screen(0..<30))
        fixture.pending.run()
        #expect(fixture.maps.total == 0)
        #expect(fixture.patched.isEmpty)
        #expect(try fixture.snapshot().armed == 30)
    }

    @Test func aStaleRowInTheOverscanIsMappedOnceInAFrontendFlush() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[300]
        fixture.set(row, "running")
        fixture.pending.run()

        fixture.feed.watch(fixture.screen(310..<340)) // 300 is in the overscan above
        #expect(fixture.maps.total == 0)
        #expect(fixture.pending.causes == [.frontend])
        fixture.pending.run()
        #expect(fixture.maps.counts[row] == 1)
        #expect(fixture.maps.total == 1)
        #expect(try fixture.snapshot().armed == 30)

        fixture.feed.watch(fixture.screen(290..<320))
        fixture.pending.run()
        #expect(fixture.maps.total == 1, "current since its map: it comes on screen with no map")
        #expect(try fixture.snapshot().armed == 30)
    }

    @Test func aRowQueuedThenScrolledAwayStaysStaleUntilItComesBack() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[10]
        fixture.set(row, "running") // queued: its flush has not run
        fixture.feed.watch(fixture.screen(200..<230))
        fixture.pending.run()
        #expect(fixture.maps.counts[row] == nil, "a queued row that went away is not mapped")

        fixture.feed.watch(fixture.screen(0..<30))
        #expect(fixture.maps.counts[row] == 1, "mapped in the scroll's own turn")
        #expect(fixture.patched.flatMap { $0 }.contains { $0.id == row && $0.status == "running" })
    }

    @Test func aQueuedRowThatComesNearMovesToTheFrontendLane() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[10]
        fixture.set(row, "running") // a program change: the budgeted program lane
        #expect(fixture.pending.causes == [.program])

        fixture.feed.watch(fixture.screen(20..<50)) // 10 is now in the overscan above
        #expect(fixture.pending.causes == [.program, .frontend])
        fixture.pending.run(only: .frontend)
        #expect(fixture.maps.counts[row] == 1, "the frontend flush maps it, not the program lane behind a burst")
        fixture.pending.run()
        #expect(fixture.maps.counts[row] == 1)
    }

    @Test func rowsTheListDoesNotDrawStayArmed() throws {
        let fixture = Fixture(rows: 100)
        fixture.pass()
        // Rows 50..<100 are in a collapsed group (not drawn as rows): they stay armed.
        fixture.feed.watch(drawn: fixture.rows(0..<50), fixture.screen(0..<10))
        #expect(try fixture.snapshot().armed == 60)

        let hidden = fixture.ids[80]
        fixture.set(hidden, "running")
        fixture.maps.reset()
        fixture.pending.run()
        #expect(fixture.maps.counts[hidden] == 1)
    }

    @Test func aMemberAGroupHeaderOnScreenRollsUpIsMappedInTheAutomationLane() throws {
        let fixture = try Self.scrolledToTop()
        // A header on screen rolls up members 0..<400 (one open group of every row).
        fixture.feed.watch(fixture.screen(0..<30, rollUp: 0..<400))
        #expect(try fixture.snapshot().armed == 30, "its off-screen members are not armed")
        #expect(fixture.maps.total == 0)

        let member = fixture.ids[300]
        fixture.set(member, "running")
        #expect(fixture.pending.causes == [.automation], "behind every other row's flush")
        fixture.pending.run()
        #expect(fixture.maps.counts[member] == 1, "the header's roll-up catches up")
        #expect(fixture.patches.ids == [member])
        #expect(try fixture.snapshot().armed == 30)

        fixture.feed.watch(fixture.screen(0..<30))
        fixture.set(member, "done")
        fixture.pending.run()
        #expect(fixture.maps.total == 1, "the header left the screen: its members' changes map nothing")
    }

    @Test func aRowTheListStopsDrawingIsObservedAgain() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[300]
        fixture.set(row, "running") // off screen: not mapped
        // Its group collapsed: the list no longer draws it as a row, and the header rolls its state up.
        fixture.feed.watch(drawn: Set(fixture.ids).subtracting([row]), fixture.screen(0..<30))
        fixture.pending.run()
        #expect(fixture.maps.total == 1, "only the row whose drawn state moved is mapped")
        #expect(fixture.patches.ids == [row])
        #expect(try fixture.snapshot().armed == 31)
    }

    @Test func noListMapsTheStaleRowsNowAndArmsEveryRow() throws {
        let fixture = try Self.scrolledToTop()
        fixture.set(fixture.ids[300], "running")
        fixture.set(fixture.ids[301], "running")
        // A filter or Group by Status starts: it reads every row, in this turn.
        fixture.feed.watch(drawn: nil, SidebarRowFeed.Viewport())
        #expect(fixture.maps.total == 2, "only the rows that changed off screen are mapped")
        #expect(Set(fixture.patches.ids) == [fixture.ids[300], fixture.ids[301]])
        #expect(try fixture.snapshot().armed == 400)
        fixture.pending.run()
        #expect(fixture.maps.total == 2)
    }

    @Test func refreshAllMapsOnlyTheStaleRows() throws {
        let fixture = try Self.scrolledToTop()
        fixture.set(fixture.ids[300], "running")
        fixture.feed.refreshAll()
        #expect(fixture.maps.total == 1)
        #expect(fixture.patches.ids == [fixture.ids[300]])
        #expect(try fixture.snapshot().armed == 30, "the row stays off screen: a sentinel")
        fixture.set(fixture.ids[300], "done")
        fixture.pending.run()
        #expect(fixture.maps.total == 1)
    }

    @Test func anInputsChangeMapsOnlyTheRowsOnScreen() throws {
        let fixture = try Self.scrolledToTop()
        fixture.pass(inputs: 1)
        #expect(fixture.maps.total == 30, "the rows off screen keep their row until they come back")
        #expect(try fixture.snapshot().armed == 30)

        fixture.maps.reset()
        fixture.feed.watch(fixture.screen(100..<130))
        #expect(fixture.maps.total == 30, "the stale rows on screen are mapped in the scroll's turn")
        fixture.pending.run()
        #expect(fixture.maps.total == 60, "and the stale overscan rows in one frontend flush")
        #expect(fixture.patched.flatMap { $0 }.contains { $0.id == fixture.ids[120] && $0.title.hasSuffix(" 1") })
    }

    @Test func aPassMapsNoRowOffScreen() throws {
        let fixture = try Self.scrolledToTop()
        fixture.pass()
        #expect(fixture.maps.total == 0)
        #expect(try fixture.snapshot().armed == 30)
    }

    @Test func aNewRowOffScreenIsMappedOnceAndNotArmed() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[300]
        fixture.pass(only: fixture.ids.filter { $0 != row }) // the row leaves the list, then comes back
        _ = try fixture.snapshot()
        fixture.maps.reset()
        fixture.pass()
        #expect(fixture.maps.counts[row] == 1, "a new row is mapped once: its title and height place it")
        #expect(fixture.maps.total == 1)
        #expect(try fixture.snapshot().armed == 30, "and not armed while off screen")
    }

    @Test func aHiddenSidebarArmsNoRow() throws {
        let fixture = try Self.scrolledToTop()
        let window = VisibilityNode(root: "window", own: .visible)
        let sidebar = VisibilityNode("sidebar", parent: window)
        fixture.feed.follow(visibility: sidebar)
        #expect(try fixture.snapshot().armed == 30)

        window.set(.hidden)
        #expect(try fixture.snapshot().armed == 0)
        let row = fixture.ids[10]
        fixture.set(row, "running")
        fixture.pending.run()
        #expect(fixture.maps.total == 0, "a change while hidden maps nothing")

        window.set(.visible)
        #expect(fixture.maps.counts[row] == 1, "the stale row on screen is mapped as the window shows")
        #expect(fixture.maps.total == 1)
        #expect(try fixture.snapshot().armed == 30)
        withExtendedLifetime(sidebar) {} // the tree holds nodes weakly
    }
}
