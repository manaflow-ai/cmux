import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// MayBlockRunner (plans/cmux-next/chrome-parity/p02-threads.md, task 014): the Compat seam that modules below
/// Wakeups take by init runs on BackgroundWork's lanes with WorkPriority's levels, QoS and shutdown behavior.
@Suite(.timeLimit(.minutes(1))) struct MayBlockRunnerTests {
    /// Where a lane body ran: its dispatch queue label and its thread's QoS.
    struct Seen: Sendable {
        var queue: String
        var qos: qos_class_t

        static func here() -> Seen {
            Seen(queue: String(cString: __dispatch_queue_get_label(nil)), qos: qos_class_self())
        }
    }

    @Test func everyLevelMapsToTheWorkPriorityOfTheSameNameAndQoS() {
        #expect(MayBlockPriority.allCases.map { WorkPriority($0) } == WorkPriority.allCases)
        for priority in MayBlockPriority.allCases {
            let work = WorkPriority(priority)
            #expect("\(work)" == "\(priority)")
            #expect(work.rawValue == priority.rawValue)
            #expect(work.qos == priority.qos)
        }
    }

    @Test func everyShutdownMapsToTheBehaviorOfTheSameName() {
        #expect(ShutdownBehavior(.continueOnShutdown) == .continueOnShutdown)
        #expect(ShutdownBehavior(.skipOnShutdown) == .skipOnShutdown)
        #expect(ShutdownBehavior(.blockShutdown) == .blockShutdown)
    }

    @Test(arguments: MayBlockPriority.allCases)
    func aPostedItemRunsOnItsFilesSlotAtItsQoS(priority: MayBlockPriority) async throws {
        let runner: any MayBlockRunner = BackgroundWork(label: "test.mbr")
        // Posted, not awaited: an awaiting caller would boost the item to its own priority.
        let (reports, report) = AsyncStream.makeStream(of: Seen.self)
        runner.postFiles(priority, shutdown: .skipOnShutdown) { report.yield(Seen.here()) }
        var iterator = reports.makeAsyncIterator()
        let seen = try #require(await iterator.next())
        #expect(seen.queue == "test.mbr.files.\(WorkPriority(priority))")
        #expect(seen.qos == priority.qos.qosClass.rawValue)
    }

    @Test func runFilesAndRunSystemUseTheirLanesAndReturnTheResult() async throws {
        let runner: any MayBlockRunner = BackgroundWork(label: "test.mbr")
        let files = try await runner.runFiles(.userVisible) { Seen.here() }
        let system = try await runner.runSystem(.userBlocking) { Seen.here() }
        #expect(files.queue.hasPrefix("test.mbr.files."), "ran on \(files.queue)")
        #expect(system.queue.hasPrefix("test.mbr.system."), "ran on \(system.queue)")
        #expect(!files.queue.contains("cooperative") && !system.queue.contains("cooperative"))
    }

    @Test func afterShutdownOnlyABlockShutdownItemRuns() async throws {
        let work = BackgroundWork(label: "test.mbr")
        let runner: any MayBlockRunner = work
        await work.shutdown()
        // The overloads without a shutdown argument are skipOnShutdown, so shutdown refuses them.
        await #expect(throws: CancellationError.self) { try await runner.runFiles(.userVisible) { 1 } }
        await #expect(throws: CancellationError.self) { try await runner.runSystem(.userVisible) { 1 } }
        let saved = try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) { 7 }
        let asked = try await runner.runSystem(.bestEffort, shutdown: .blockShutdown) { 8 }
        #expect(saved == 7)
        #expect(asked == 8)
    }
}
