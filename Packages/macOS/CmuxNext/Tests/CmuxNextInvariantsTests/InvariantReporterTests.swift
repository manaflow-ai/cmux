#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
@testable import CmuxNextInvariants
import Foundation
import Testing

/// The reports leave the violating turn (plans/cmux-next/invariants-DESIGN.md section 4): violations waiting for the
/// capture turn share one read of the app's facts and one file; the files lane encodes the states; the ledger names
/// the report only once it is written.
@MainActor @Suite(.serialized)
struct InvariantReporterTests {
    @Test func violationsThatWaitShareOneCaptureAndOneFileAndTheLedgerNamesItOnceWritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "invariant-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = InvariantTestClock()
        let registry = clock.registry()
        let world = InvariantTestWorld()
        registry.declare(world.stripRule())
        let lanes = HeldLanes()
        let deliveries = HeldDeliveries()
        let fixture = ReporterFixture()
        let reporter = InvariantReporter(
            registry: registry, store: InvariantReportStore(tag: "t", runner: lanes, logs: directory),
            post: { fixture.posted.append($0) }, deliver: { deliveries.hold($0) },
            journal: { batch in
                fixture.journaled += batch.count
                return 7
            },
            capture: {
                fixture.captures += 1
                return ["debug_focus": { Data(#"{"key": "window_1"}"#.utf8) }]
            })
        registry.onReports = { reporter.take($0) }
        world.strips["p1"] = .init(pane: "p1", shown: 1, held: 2)
        registry.noteAction("tab.move", origin: "cli")
        registry.runTurn()
        world.strips["p2"] = .init(pane: "p2", shown: 0, held: 1)
        registry.touch(.tabs, .pane("p2"))
        registry.runTurn()
        #expect(fixture.journaled == 2, "each batch is journaled in its own turn")
        #expect(fixture.posted.count == 1, "one capture turn for every violation that waits")
        #expect(fixture.captures == 0, "nothing is read in the violating turns")
        #expect(registry.ledger.since(0).violations.allSatisfy { $0.journalTail == 7 && $0.report == nil })
        fixture.posted.removeFirst()()
        #expect(fixture.captures == 1)
        #expect(registry.ledger.since(0).violations.allSatisfy { $0.report == nil }, "no report path before the write")
        lanes.runAll()
        #expect(registry.ledger.since(0).violations.allSatisfy { $0.report == nil }, "named only on the main actor's delivery")
        deliveries.runAll()
        let violations = registry.ledger.since(0).violations
        let path = try #require(violations.first?.report)
        #expect(violations.allSatisfy { $0.report == path && $0.state != nil }, "named and given its state once written")
        #expect(path.hasSuffix("0001-T1+1.json"))
        let report = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: path))) as? [String: Any])
        #expect((report["violations"] as? [[String: Any]])?.count == 2)
        #expect((report["debug_focus"] as? [String: String])?["key"] == "window_1")
        let first = try #require((report["violations"] as? [[String: Any]])?.first)
        #expect((first["trigger"] as? [String: Any])?["kind"] as? String == "action")
        #expect((first["state"] as? [[String: Any]])?.first?["pane"] as? String == "p1")
    }
}

/// The app's facts and turns as a reporter sees them.
@MainActor
private final class ReporterFixture {
    var posted: [@MainActor () -> Void] = []
    var journaled = 0
    var captures = 0
}

/// The main actor's deliveries from the files lane, held until the test (on the main actor) runs them: the
/// reporter's `deliver` is called off the main actor, and the work it hands over runs only here.
private final class HeldDeliveries: Sendable {
    // concurrency-allow: a test double's queue of held deliveries; the lock is held only to append or take them
    private let held = Mutex<[@MainActor @Sendable () -> Void]>([])

    func hold(_ work: @escaping @MainActor @Sendable () -> Void) {
        held.withLock { $0.append(work) }
    }

    @MainActor func runAll() {
        let works = held.withLock { works in
            defer { works = [] }
            return works
        }
        for work in works { work() }
    }
}

/// Files lanes that hold every job until the test runs them.
private final class HeldLanes: MayBlockRunner {
    // concurrency-allow: a test double's queue of held jobs; the lock is held only to append or take them
    private let held = Mutex<[@Sendable () -> Void]>([])

    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T { try body() }
    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void) { held.withLock { $0.append(body) } }

    func runAll() {
        let jobs = held.withLock { jobs in
            defer { jobs = [] }
            return jobs
        }
        for job in jobs { job() }
    }
}
#endif
