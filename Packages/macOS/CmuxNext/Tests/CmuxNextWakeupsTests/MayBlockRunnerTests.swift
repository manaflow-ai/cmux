import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
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

    /// The dispatch class of a child process's `QualityOfService`.
    static func qosClass(_ qos: QualityOfService) -> DispatchQoS.QoSClass {
        switch qos {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        case .default: .default
        @unknown default: .unspecified
        }
    }

    @Test func everyLevelMapsToTheWorkPriorityOfTheSameNameAndQoS() {
        #expect(MayBlockPriority.allCases.map { WorkPriority($0) } == WorkPriority.allCases)
        for priority in MayBlockPriority.allCases {
            let work = WorkPriority(priority)
            #expect("\(work)" == "\(priority)")
            #expect(work.rawValue == priority.rawValue)
            // A spawn of the level (MayBlockPriority.qos) runs at the child QoS of the same name; a lane item runs
            // at the lane QoS, which is userInitiated for userVisible too (threading-model.md, "QoS and task priority").
            #expect(Self.qosClass(work.processQoS) == priority.qos.qosClass)
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
        #expect(seen.queue.hasPrefix("test.mbr.files.\(WorkPriority(priority))."), "ran on \(seen.queue)")
        #expect(seen.qos == WorkPriority(priority).qos.qosClass.rawValue)
    }

    @Test func runFilesAndRunSystemUseTheirLanesAndReturnTheResult() async throws {
        let runner: any MayBlockRunner = BackgroundWork(label: "test.mbr")
        let files = try await runner.runFiles(.userVisible) { Seen.here() }
        let system = try await runner.runSystem(.userBlocking) { Seen.here() }
        #expect(files.queue.hasPrefix("test.mbr.files."), "ran on \(files.queue)")
        #expect(system.queue.hasPrefix("test.mbr.system."), "ran on \(system.queue)")
        #expect(!files.queue.contains("cooperative") && !system.queue.contains("cooperative"))
    }

    @Test func afterShutdownBeganOnlyABlockShutdownItemRuns() async throws {
        let work = BackgroundWork(label: "test.mbr")
        let runner: any MayBlockRunner = work
        work.beginShutdown()
        // The overloads without a shutdown argument are skipOnShutdown, so shutdown refuses them.
        await #expect(throws: CancellationError.self) { try await runner.runFiles(.userVisible) { 1 } }
        await #expect(throws: CancellationError.self) { try await runner.runSystem(.userVisible) { 1 } }
        let saved = try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) { 7 }
        let asked = try await runner.runSystem(.bestEffort, shutdown: .blockShutdown) { 8 }
        #expect(saved == 7)
        #expect(asked == 8)
        // Once shutdown has returned, nothing waits for a save: it is refused too.
        await work.shutdown()
        await #expect(throws: CancellationError.self) { try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) { 1 } }
    }

    #if DEBUG
    @Test func aSlowBlockItemThroughTheRunnerIsRecordedAtItsCallersSite() async throws {
        // Every read of the clock moves it 300 ms: each block item runs past the 250 ms limit.
        let uptime = BackgroundWorkTaskTests.SteppingUptime(stepMilliseconds: 300)
        let work = BackgroundWork(label: "test.mbr.overrun", uptimeNanos: { uptime.read() })
        let runner: any MayBlockRunner = work
        _ = try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) { 1 }
        _ = try await runner.runSystem(.bestEffort, shutdown: .blockShutdown) { 1 }
        runner.postFiles(.bestEffort, shutdown: .blockShutdown) {}
        // Shutdown returns after each item's done step, which follows its record.
        await work.shutdown()
        let sites = work.blockShutdownOverruns.map(\.site)
        #expect(sites.count == 3, "\(sites)")
        // The caller's line, never the adapter's (BackgroundWork+MayBlockRunner.swift).
        #expect(sites.allSatisfy { $0.hasPrefix("CmuxNextWakeupsTests/MayBlockRunnerTests.swift:") }, "\(sites)")
    }
    #endif
}
