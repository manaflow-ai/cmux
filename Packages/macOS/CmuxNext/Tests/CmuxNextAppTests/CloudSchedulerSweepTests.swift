import AppKit
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextApp/{Cloud,SessionTransfer,ServerUpdates} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md):
/// one case per migrated owner class. The New Cloud Workspace progress view reads nothing
/// while its window is hidden and catches up once when it shows, and its elapsed ticker wakes only while it shows;
/// a create's backoff is a classed `MainDeadline` on the app's one scheduler (here a rig whose wakes the test fires).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CloudSchedulerSweepTests {
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "no capacity" }
    }

    private static func progressView(_ creation: CloudMachineCreation, parent: VisibilityNode,
                                      rig: MainDeadlineRig) -> (CloudMachineProgressView, NSWindow) {
        _ = NSApplication.shared
        let view = CloudMachineProgressView(creation: creation, actions: .init(retry: { _ in }, dismiss: { _ in }),
                                            parent: parent, mainWork: rig.deadlines.work, deadlines: rig.deadlines)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, window)
    }

    // MARK: VisibleObservation on the window's node (CloudMachineProgressView)

    @Test func aHiddenWindowsProgressViewRendersAFailureOnlyWhenItShows() {
        let rig = MainDeadlineRig(), parent = VisibilityNode(root: "window", own: .hidden)
        let creation = CloudMachineCreation(windowID: nil)
        let (view, window) = Self.progressView(creation, parent: parent, rig: rig)
        defer { window.close() }
        let before = view.detailText
        #expect(!view.showsButtons)

        creation.fail(Refused())
        rig.frame()
        #expect(view.detailText == before, "a hidden window's progress view rendered the failure")
        #expect(!view.showsButtons)

        parent.set(.visible)
        #expect(view.detailText != before, "the progress view did not render the failure in the show turn")
        #expect(view.showsButtons, "the shown failure offers no Retry")
    }

    // MARK: MainDeadline (the elapsed ticker)

    @Test func theElapsedTickerWakesOnlyWhileTheViewShows() {
        let rig = MainDeadlineRig(), parent = VisibilityNode(root: "window", own: .visible)
        let creation = CloudMachineCreation(windowID: nil)
        let (_, window) = Self.progressView(creation, parent: parent, rig: rig)
        defer { window.close() }
        #expect(rig.deadlines.nextFire.map { $0 >= .seconds(1) && $0 <= .seconds(2) } == true,
                "a shown, running creation planned no elapsed tick one second away")

        parent.set(.hidden)
        #expect(rig.deadlines.nextFire == nil, "a hidden progress view kept its elapsed wake")

        parent.set(.visible)
        #expect(rig.deadlines.nextFire != nil, "the shown view did not tick again")
        creation.fail(Refused())
        rig.frame()
        #expect(rig.deadlines.nextFire == nil, "a finished creation kept ticking")
    }

    // MARK: MainPause (the create flow's approval backoff)

    @Test func aPauseResumesWhenItsDeadlineFiresNotBefore() async throws {
        let rig = MainDeadlineRig()
        let pause = MainPause(owner: "test.pause", workClass: .visible, scheduler: rig.deadlines)
        let waiter = Task { try await pause.delay(.seconds(2)) }
        while !pause.isWaiting { await Task.yield() }
        #expect(rig.hasArmedWake, "the pause armed no wake on the main thread's queue")
        rig.frame()
        #expect(pause.isWaiting, "a frame with no wake ended the pause")

        rig.fireAndRun()
        try await waiter.value
        #expect(rig.elapsed >= 2, "the pause ended \(rig.elapsed) s in, before its 2 s")
        #expect(!rig.hasArmedWake)
    }

    // MARK: A creation's run, awaited off main (CloudCreationFlow)

    /// A flow whose create calls wait in `gate`, on `rig`'s scheduler (no window: show is never reached here).
    private static func flow(_ rig: MainDeadlineRig, gate: CreateGate) -> CloudCreationFlow {
        let creations = CloudCreations(work: BackgroundWork(label: "test.creation-runs"), mainWork: rig.deadlines.work)
        return CloudCreationFlow(creations: creations, create: { _ in try await gate.next() }, open: { _ in "workspace" },
                                 show: { _, _ in })
    }

    /// Lets the first run's create end with `error`, then returns once its step is queued on main (checked, not run).
    private static func queueFirstRunsStep(_ gate: CreateGate, _ error: any Error, rig: MainDeadlineRig) async {
        await gate.waitForCalls(1)
        gate.failOldest(error)
        let end = ContinuousClock.now + .seconds(5)
        while rig.deadlines.work.postedCount(.visible) == 0, ContinuousClock.now < end { await Task.yield() }
    }

    @Test func aRetriedCreationIgnoresTheCancelledRunsQueuedFailure() async throws {
        let rig = MainDeadlineRig(), gate = CreateGate()
        let flow = Self.flow(rig, gate: gate)
        let creation = flow.start(in: nil, existing: nil)
        await Self.queueFirstRunsStep(gate, Refused(), rig: rig)
        #expect(rig.deadlines.work.postedCount(.visible) == 1, "the first run's failure was not queued")

        // The Retry cancels the first run after its check: its queued step must not land on the new attempt.
        flow.retry(creation)
        await gate.waitForCalls(2)
        rig.frame()
        #expect(creation.phase == .requesting, "the cancelled run's failure landed on the retried creation: \(creation.phase)")
        #expect(flow.creations.creation(creation.id) != nil)
        flow.dismiss(creation, in: nil)
        gate.failOldest(CancellationError())
    }

    @Test func aRetriedCreationStaysWhenTheCancelledRunsDeclineArrives() async throws {
        let rig = MainDeadlineRig(), gate = CreateGate()
        let flow = Self.flow(rig, gate: gate)
        let creation = flow.start(in: nil, existing: nil)
        await Self.queueFirstRunsStep(gate, CloudMachineCreateFlow.Failure.declined, rig: rig)
        #expect(rig.deadlines.work.postedCount(.visible) == 1, "the first run's decline was not queued")

        flow.retry(creation)
        await gate.waitForCalls(2)
        rig.frame()
        #expect(flow.creations.creation(creation.id) != nil, "the cancelled run's decline removed the retried creation")
        flow.dismiss(creation, in: nil)
        gate.failOldest(CancellationError())
    }
}

/// The create calls of a test flow: each waits until the test ends it.
@MainActor
private final class CreateGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<CloudMachineSession, any Error>] = []

    func next() async throws -> CloudMachineSession {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    /// Ends the oldest create call still waiting with `error`.
    func failOldest(_ error: any Error) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(throwing: error)
    }

    /// Returns once `count` create calls started (each runs on main, hopped to from the run off main).
    func waitForCalls(_ count: Int) async {
        let end = ContinuousClock.now + .seconds(5)
        while calls < count, ContinuousClock.now < end { await Task.yield() }
    }
}
