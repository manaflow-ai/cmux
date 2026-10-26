import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The row feed observes only the rows the list draws near its viewport (p06-scheduler-040, feature
/// `sidebarRowsNearViewport`): 400 rows with 30 on screen arm at most 60 observations, a change of a row
/// away from the viewport maps nothing, and the row is mapped once when it scrolls back near.
@MainActor @Suite struct SidebarRowFeedTests {
    @Observable final class Status {
        var text = "idle"
    }

    final class Pending {
        var work: [@MainActor @Sendable () -> Void] = []
        func run() {
            while !work.isEmpty {
                let batch = work
                work.removeAll()
                batch.forEach { $0() }
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
    }

    struct Fixture {
        let feed: SidebarRowFeed
        let ledger: ObservationLedger
        let pending: Pending
        let maps = Maps()
        let patches: Patches
        let ids: [WorkspaceID]
        let status: [WorkspaceID: Status]
        var patched: [[SidebarWorkspace]] { patches.rows }

        init(rows: Int) {
            let ledger = ObservationLedger(), pending = Pending(), patches = Patches()
            let feed = SidebarRowFeed(schedule: { pending.work.append($0) }, observations: ledger.owner("SidebarRows"))
            feed.onChange = { patches.rows.append($0) }
            self.feed = feed
            self.ledger = ledger
            self.pending = pending
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

        func snapshot() throws -> ObservationLedger.Entry {
            try #require(ledger.snapshot(resetting: true).first)
        }
    }

    /// 400 rows, rows 0..<30 on screen and half a screen past them each way (the list's near set: 0..<45 at the top).
    static func scrolledToTop() throws -> Fixture {
        let fixture = Fixture(rows: 400)
        fixture.pass()
        fixture.feed.watch(drawn: Set(fixture.ids), near: fixture.rows(0..<45))
        fixture.pending.run()
        return fixture
    }

    @Test func onlyRowsNearTheViewportStayArmed() throws {
        let fixture = Fixture(rows: 400)
        fixture.pass()
        #expect(try fixture.snapshot().armed == 400, "without a list every row is observed")

        // 30 rows on screen in the middle, and one screen of overscan: 60 rows near.
        fixture.feed.watch(drawn: Set(fixture.ids), near: fixture.rows(185..<245))
        fixture.pending.run()
        let entry = try fixture.snapshot()
        #expect(entry.armed <= 60)
        #expect(entry.armed == 60)
        #expect(entry.evaluations == 0, "the rows near were armed already: nothing is mapped again")
    }

    @Test func aChangeAwayFromTheViewportMapsNothing() throws {
        let fixture = try Self.scrolledToTop()
        fixture.maps.reset()
        _ = try fixture.snapshot()

        fixture.set(fixture.ids[300], "running")
        fixture.pending.run()
        #expect(fixture.maps.total == 0)
        #expect(try fixture.snapshot().evaluations == 0)
        #expect(fixture.patched.isEmpty)
    }

    @Test func aRowScrolledBackNearIsMappedOnce() throws {
        let fixture = try Self.scrolledToTop()
        let away = fixture.ids[300]
        fixture.set(away, "running")
        fixture.pending.run()
        fixture.maps.reset()
        _ = try fixture.snapshot()

        fixture.feed.watch(near: fixture.rows(280..<340))
        fixture.pending.run()
        #expect(fixture.maps.counts[away] == 1, "scroll-in maps the changed row once")
        #expect(fixture.patched.flatMap { $0 }.map(\.id) == [away], "only the row that changed is patched")
        #expect(fixture.patched.last?.first?.status == "running")
        let entry = try fixture.snapshot()
        #expect(entry.armed == 60, "the rows that left are disarmed, the ones that came are armed")

        fixture.maps.reset()
        fixture.feed.watch(near: fixture.rows(280..<340))
        fixture.pending.run()
        #expect(fixture.maps.total == 0, "the same viewport maps nothing again")
    }

    @Test func aRowQueuedThenScrolledAwayStaysStaleUntilItComesBack() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[10]
        fixture.set(row, "running")  // queued: its flush has not run
        fixture.feed.watch(near: fixture.rows(200..<260))
        fixture.maps.reset()
        fixture.pending.run()
        #expect(fixture.maps.counts[row] == nil, "a queued row that went away is not mapped")

        fixture.feed.watch(near: fixture.rows(0..<60))
        fixture.pending.run()
        #expect(fixture.maps.counts[row] == 1)
        #expect(fixture.patched.flatMap { $0 }.contains { $0.id == row && $0.status == "running" })
    }

    @Test func rowsTheListDoesNotDrawStayObserved() throws {
        let fixture = Fixture(rows: 100)
        fixture.pass()
        // Rows 50..<100 are in a collapsed group (not drawn as rows): they keep their observation.
        fixture.feed.watch(drawn: fixture.rows(0..<50), near: fixture.rows(0..<10))
        let entry = try fixture.snapshot()
        #expect(entry.armed == 60)

        let hidden = fixture.ids[80]
        fixture.set(hidden, "running")
        fixture.maps.reset()
        fixture.pending.run()
        #expect(fixture.maps.counts[hidden] == 1)
    }

    @Test func aRowTheListStopsDrawingIsObservedAgain() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[300]
        fixture.set(row, "running")  // away: not mapped
        _ = try fixture.snapshot()
        fixture.maps.reset()
        // Its group collapsed: the list no longer draws it as a row, and the header rolls its state up.
        fixture.feed.watch(drawn: Set(fixture.ids).subtracting([row]), near: fixture.rows(0..<45))
        fixture.pending.run()
        #expect(fixture.maps.total == 1, "only the row whose drawn state moved is mapped")
        #expect(fixture.patched.flatMap { $0 }.map(\.id) == [row])
        #expect(try fixture.snapshot().armed == 46)
    }

    @Test func noListObservesEveryRowAgain() throws {
        let fixture = try Self.scrolledToTop()
        _ = try fixture.snapshot()
        fixture.maps.reset()
        fixture.feed.watch(drawn: nil, near: [])
        fixture.pending.run()
        #expect(try fixture.snapshot().armed == 400)
        #expect(fixture.maps.total == 355, "each row that was away is mapped once")
    }

    @Test func anInputsChangeMapsOnlyTheRowsNear() throws {
        let fixture = try Self.scrolledToTop()
        _ = try fixture.snapshot()
        fixture.maps.reset()
        fixture.pass(inputs: 1)
        #expect(fixture.maps.total == 45, "the rows away keep their row until they come near")
        #expect(try fixture.snapshot().armed == 45)

        fixture.maps.reset()
        fixture.feed.watch(near: fixture.rows(100..<145))
        fixture.pending.run()
        #expect(fixture.maps.total == 45)
        #expect(fixture.patched.flatMap { $0 }.contains { $0.id == fixture.ids[120] && $0.title.hasSuffix(" 1") })
    }

    @Test func aPassMapsNoRowAwayFromTheViewport() throws {
        let fixture = try Self.scrolledToTop()
        _ = try fixture.snapshot()
        fixture.maps.reset()
        fixture.pass()
        #expect(fixture.maps.total == 0)
        #expect(try fixture.snapshot().armed == 45)
    }

    @Test func aNewRowAwayFromTheViewportIsMappedOnceAndNotArmed() throws {
        let fixture = try Self.scrolledToTop()
        let row = fixture.ids[300]
        fixture.pass(only: fixture.ids.filter { $0 != row })  // the row leaves the list, then comes back
        _ = try fixture.snapshot()
        fixture.maps.reset()
        fixture.pass()
        #expect(fixture.maps.counts[row] == 1, "a new row is mapped once: its title and height place it")
        #expect(fixture.maps.total == 1)
        #expect(try fixture.snapshot().armed == 45, "and not observed while away from the viewport")
    }
}
