import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The sidebar rows record into `debug.observations`: the rows armed now, and per status
/// change one re-read and, when the row changed, one apply; a change of the pass's inputs re-reads every row.
/// Without the feed recording, the ledger reads 0 for every sidebar size and the bench's budget check
/// (`sidebar-stress-bench.py` observations: armed rows and evaluations per change) passes with nothing measured.
@MainActor @Suite struct SidebarRowFeedObservationsTests {
    @Observable final class Status {
        var text = "idle"
        var other = 0
    }

    final class Pending {
        var work: [@MainActor @Sendable () -> Void] = []
        func run() {
            let batch = work
            work.removeAll()
            batch.forEach { $0() }
        }
    }

    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    /// `inputs` stand for the pass's by-value inputs (the unread visibility): a row maps its title with them.
    static func pass(_ feed: SidebarRowFeed, _ ids: [WorkspaceID], status: [WorkspaceID: Status],
                     inputs: Int = 0) -> [SidebarSection] {
        feed.beginPass(inputs: inputs)
        let rows = ids.map { id in
            feed.row(id, machine: .local) { [status] in
                let source = status[id]
                _ = source?.other
                return SidebarWorkspace(id: id, machineID: .local, title: "\(id.rawValue) \(inputs)",
                                        status: source?.text ?? "")
            }
        }
        return [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })]
    }

    @Test func oneStatusChangeIsOneEvaluationAndOneApply() throws {
        let ledger = ObservationLedger()
        let pending = Pending()
        let feed = SidebarRowFeed(schedule: { pending.work.append($0) }, observations: ledger.owner("SidebarRows"))
        let ids = (0..<50).map { WorkspaceID("w\($0)") }
        let status = Dictionary(uniqueKeysWithValues: ids.map { ($0, Status()) })
        _ = feed.fill(Self.pass(feed, ids, status: status))
        let first = try #require(ledger.snapshot(resetting: true).first)
        #expect(first.armed == 50 && first.arms == 50, "every row is armed once")

        let third = try #require(status[ids[3]])
        third.text = "running"
        pending.run()
        let changed = try #require(ledger.snapshot(resetting: true).first)
        #expect(changed.evaluations == 1 && changed.applies == 1)
        #expect(changed.armed == 50, "the row is armed again after its flush")

        let fourth = try #require(status[ids[4]])
        fourth.other += 1  // read by the row, but its row does not change
        pending.run()
        let same = try #require(ledger.snapshot().first)
        #expect(same.evaluations == 1 && same.applies == 0, "an equal row is evaluated, not applied")
    }

    @Test func forgottenRowsAreDisarmed() throws {
        let ledger = ObservationLedger()
        let feed = SidebarRowFeed(schedule: { _ in }, observations: ledger.owner("SidebarRows"))
        let ids = (0..<20).map { WorkspaceID("w\($0)") }
        _ = feed.fill(Self.pass(feed, ids, status: [:]))
        _ = feed.fill(Self.pass(feed, Array(ids.prefix(5)), status: [:]))
        #expect(ledger.snapshot().first?.armed == 5)
        feed.reset()
        #expect(ledger.snapshot().first?.armed == 0)
    }

    @Test func inputsChangeIsOneEvaluationPerRow() throws {
        let ledger = ObservationLedger()
        let feed = SidebarRowFeed(schedule: { _ in }, observations: ledger.owner("SidebarRows"))
        let ids = (0..<40).map { WorkspaceID("w\($0)") }
        _ = feed.fill(Self.pass(feed, ids, status: [:]))
        let first = try #require(ledger.snapshot(resetting: true).first)
        #expect(first.evaluations == 0 && first.applies == 0, "a new row's first map is an arm only")

        _ = feed.fill(Self.pass(feed, ids, status: [:], inputs: 1))
        let remapped = try #require(ledger.snapshot(resetting: true).first)
        #expect(remapped.evaluations == 40 && remapped.applies == 40, "every row is re-read, and each one changed")
        #expect(remapped.armed == 40 && remapped.arms == 40, "each row is armed again once")

        _ = feed.fill(Self.pass(feed, ids, status: [:], inputs: 1))
        let same = try #require(ledger.snapshot().first)
        #expect(same.evaluations == 0, "the same inputs re-read no row")
    }
}
