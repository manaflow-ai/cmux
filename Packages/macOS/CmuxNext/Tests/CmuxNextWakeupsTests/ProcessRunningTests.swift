@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Dispatch
import Foundation
import Testing

/// The child-process seams of plans/cmux-next/chrome-parity/p02-threads.md (tasks 038-040): a request's stated
/// priority sets its child's QoS whatever task awaits it; ProcessLauncher spawns on its queue at its priority and
/// reports the start; a wait with a limit gives up without stopping the child.
@Suite(.timeLimit(.minutes(1))) struct ProcessRunningTests {
    static let tool = URL(fileURLWithPath: "/usr/bin/true")

    @Test func aStatedPriorityBeatsTheAwaitingTasks() {
        let caller = WorkPriority(Task.currentPriority)
        // Whatever this task's priority, a stated one (above it or below it) is the run's, and so its child's QoS.
        for stated in [WorkPriority.idle, .userBlocking] {
            #expect(ProcessRun(ProcessRequest(Self.tool, priority: stated), clock: ContinuousClock()).priority == stated)
        }
        #expect(WorkPriority.userBlocking.processQoS == .userInitiated)
        #expect(WorkPriority.idle.processQoS == .background)
        // None stated: the awaiting task's.
        #expect(ProcessRun(ProcessRequest(Self.tool), clock: ContinuousClock()).priority == caller)
    }

    @Test func theLauncherSpawnsAtItsPriorityAndReportsTheStart() async {
        let launcher = ProcessLauncher(label: "test.process-launcher", priority: .bestEffort)
        #expect(launcher.childPriority == .bestEffort)
        let process = Process()
        process.executableURL = Self.tool
        let started = FirstOutcome<String?>()
        launcher.launch(process, started: { started.resolve(String(cString: __dispatch_queue_get_label(nil))) },
                        failed: { _ in started.resolve(nil) })
        // Set before the spawn is queued: the child runs at the launcher's priority.
        #expect(process.qualityOfService == WorkPriority.bestEffort.processQoS)
        // The spawn and `started` run on the launcher's queue, never the caller's, once the child has its pid.
        #expect(await started.value() == "test.process-launcher")
        #expect(process.processIdentifier > 0)
    }

    @Test func aLaunchThatCannotStartReportsTheFailure() async {
        let launcher = ProcessLauncher(label: "test.process-launcher", priority: .userVisible)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/cmux-test-tool")
        let started = FirstOutcome<Bool>()
        launcher.launch(process, started: { started.resolve(true) }, failed: { _ in started.resolve(false) })
        #expect(await started.value() == false)
    }

    @Test func aWaitThatEndsFirstReturnsTheOutcome() async throws {
        let processes = RecordingProcessRunner { _ in ProcessOutcome(status: 3, exited: true, output: Data("done".utf8)) }
        let outcome = try await processes.outcome(of: ProcessRequest(Self.tool, onCancel: .finish), waitingAtMost: .seconds(5),
                                                  owner: "test.wait", clock: ManualClock())
        #expect(outcome?.status == 3)
        #expect(outcome?.text == "done")
    }

    @Test func theLimitEndsTheWaitButNotTheChild() async throws {
        let release = FirstOutcome<Void>()
        let ended = FirstOutcome<Bool>()
        let processes = RecordingProcessRunner { _ in
            await release.value()
            ended.resolve(true)
            return ProcessOutcome(status: 0, exited: true, output: Data())
        }
        let clock = ManualClock()
        let wait = Task {
            try await processes.outcome(of: ProcessRequest(Self.tool, onCancel: .finish), waitingAtMost: .seconds(300),
                                        owner: "test.wait", clock: clock)
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(300))
        #expect(try await wait.value == nil)
        // The run goes on after the wait gave up, to the child's own end.
        release.resolve(())
        #expect(await ended.value())
        #expect(processes.requests.count == 1)
    }

    @Test func aCancelledCallerStopsWaitingAtOnce() async throws {
        let release = FirstOutcome<Void>()
        let processes = RecordingProcessRunner { _ in
            await release.value()
            return ProcessOutcome(status: 0, exited: true, output: Data())
        }
        let clock = ManualClock()
        let wait = Task {
            try await processes.outcome(of: ProcessRequest(Self.tool, onCancel: .finish), waitingAtMost: .seconds(300),
                                        owner: "test.wait", clock: clock)
        }
        try await clock.waitForSleeper()
        wait.cancel()
        #expect(try await wait.value == nil)
        release.resolve(())
    }

    /// One slot: the second request starts only once the first has ended, and a run that threw still frees
    /// its slot.
    @Test func aBoundedRunnerWaitsForAFreeSlotAndAThrowFreesIt() async throws {
        let release = FirstOutcome<Void>()
        let (startStream, started) = AsyncStream.makeStream(of: String.self)
        let base = RecordingProcessRunner { request in
            started.yield(request.executable.lastPathComponent)
            if request.executable.lastPathComponent == "first" {
                await release.value()
                throw ProcessFailure.launch("no such file")
            }
            return ProcessOutcome(status: 0, exited: true, output: Data())
        }
        let bounded = BoundedProcessRunner(base, atOnce: 1)
        let first = Task { try await bounded.outcome(of: ProcessRequest(URL(fileURLWithPath: "/t/first"))) }
        var starts = startStream.makeAsyncIterator()
        let firstStart = await starts.next()
        #expect(firstStart == "first")
        let second = Task { try await bounded.outcome(of: ProcessRequest(URL(fileURLWithPath: "/t/second"))) }
        for _ in 0..<20 { await Task.yield() }
        // The slot is the first run's: the second has not reached the base runner.
        #expect(base.requests.count == 1)
        release.resolve(())
        await #expect(throws: ProcessFailure.launch("no such file")) { _ = try await first.value }
        let secondStart = await starts.next()
        #expect(secondStart == "second")
        #expect(try await second.value.status == 0)
    }

    @Test func aLaunchFailureWithinTheLimitThrows() async {
        let processes = RecordingProcessRunner { _ in throw ProcessFailure.launch("no such file") }
        await #expect(throws: ProcessFailure.launch("no such file")) {
            _ = try await processes.outcome(of: ProcessRequest(Self.tool), waitingAtMost: .seconds(5), owner: "test.wait",
                                            clock: ManualClock())
        }
    }
}
