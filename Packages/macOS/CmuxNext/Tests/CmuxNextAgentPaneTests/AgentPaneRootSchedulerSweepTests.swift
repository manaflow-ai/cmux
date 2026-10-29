import AppKit
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane's main-thread work on the app's scheduler: each owner the sweep moved
/// lands as a task of its class, named in the scheduler's owners ledger, and an automation page (an agent's mail)
/// waits while the person's input is pending. Before the sweep, each of these was an unattributed main-queue job
/// (`Task { @MainActor in }`), which the ledger has no row for, and the pacer read AppKit's view tree on every
/// delivery. The pacer's hidden hold (a hidden chat holds its stream until its tab node shows) is covered by
/// AgentPaneHiddenHoldTests and AgentPaneHiddenPacingTests.
@Suite(.serialized)
@MainActor
struct AgentPaneRootSchedulerSweepTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A scheduler whose board keeps an owners ledger the test reads.
    private final class Rig {
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        lazy var work = MainWorkScheduler(budget: MainFrameBudget(board: board))

        func row(_ owner: String) -> MainOwnerLedger.Owner? {
            board.ownerSnapshot().owners.first { $0.owner == owner }
        }
    }

    /// What a callback saw, on the main actor.
    private final class Seen {
        var values: [String] = []
        var pages: [CmuxNextSettings.JSONValue] = []
        var calls = 0
    }

    /// Main run loop passes, where the scheduler's turns and off-main posts arrive, until `done` or 5 s. Each pass
    /// returns to the test's executor, so the off-main work it waits on (a reader's task, a dispatch hop) runs too.
    private static func settle(until done: () -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !done(), ContinuousClock.now < end {
            runMainRunLoopOnce()
            await Task.yield()
        }
    }

    /// One pass of the main run loop's default mode, at most 5 ms: the scheduler's posted turns
    /// (`MainRunLoopBlock`) run in it. Synchronous, so the async ``settle(until:)`` can run it.
    private static func runMainRunLoopOnce() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }

    // MARK: AgentPageProvider.replay (visible)

    /// A new subscriber's catch-up reaches its page after `subscribe` returned, as visible tasks of the provider.
    @Test func aSubscribersCatchUpLandsAsVisibleTasksAfterTheSubscription() async throws {
        let rig = Rig(), seen = Seen()
        let provider = AgentPageProvider(mainWork: rig.work) { _ in nil }
        provider.publish(.command("before-subscribe"))
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                        context: PageCallContext(page: PageDescriptor.agent.id)) { seen.pages.append($0) }
        defer { subscription.cancel() }
        #expect(seen.pages.isEmpty, "the catch-up ran inside subscribe, before the page had its subscription")
        await Self.settle { !seen.pages.isEmpty }
        #expect(seen.pages.count == 1)
        let row = try #require(rig.row("AgentPageProvider.replay"), "the catch-up ran outside the scheduler: no owner row")
        #expect(row.workClass == .visible)
    }

    // MARK: AgentPaneModel.sessionHarness (visible)

    /// A harness the socket's queue reads lands as one visible task, and only for the pane's own session.
    @Test func aSessionsHarnessLandsAsAVisibleTaskOnlyForThePanesSession() async throws {
        let rig = Rig(), seen = Seen()
        let model = AgentPaneModel(host: NoHost(), sessionId: "s1")
        model.followSessionHarness(on: rig.work) { seen.values.append($0) }
        let sessions = model.transport.sessions
        await withCheckedContinuation { (read: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for id in ["other", "s1"] {
                    sessions.observeFolder(["result": ["session": ["sessionId": id, "harness": "claude"]]], replyTo: "_acpmux/attach")
                }
                read.resume()
            }
        }
        await Self.settle { !seen.values.isEmpty && rig.row("AgentPaneModel.sessionHarness")?.tasks == 2 }
        #expect(seen.values == ["s1"], "another session's harness reached the pane's tab")
        let row = try #require(rig.row("AgentPaneModel.sessionHarness"), "the report hopped outside the scheduler")
        #expect(row.workClass == .visible)
    }

    // MARK: AcpmuxMailboxSubscription (the owner's class)

    /// Each page the reader reads off main lands as one task of the owner's class.
    @Test func aMailboxPageLandsAsOneTaskOfTheOwnersClass() async throws {
        let rig = Rig(), seen = Seen()
        let reader = AcpmuxMailboxReader(socketPath: "/nonexistent/acpmux.sock", wake: RetryWake(owner: "AgentPaneRootSchedulerSweepTests"),
                                         clock: ContinuousClock(), policy: .firstConnect) { after in
            guard after == 0 else { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
            return AcpmuxMailboxPage(messages: [], nextCursor: 1)
        }
        let subscription = AcpmuxMailboxSubscription(mainWork: rig.work, workClass: .automation, owner: "test.reports")
        let run = subscription.start(reader) { page in seen.values.append("\(page.nextCursor ?? 0)") }
        await Self.settle { !seen.values.isEmpty }
        subscription.stop()
        await run.value
        #expect(seen.values == ["1"])
        let row = try #require(rig.row("test.reports"), "the page hopped outside the scheduler")
        #expect(row.workClass == .automation)
    }

    /// An agent's mail (`FeedService.reports`, an automation subscription) does not apply ahead of the person's
    /// pending input: its page waits in the scheduler's automation queue while the input is pending, and applies on
    /// the first frame after the input drained (Chrome's input-pending check before a scheduled task).
    @Test func anAutomationPageWaitsWhileThePersonsInputIsPending() async throws {
        let rig = HeldRig(), seen = Seen()
        defer { rig.stop() }
        let reader = AcpmuxMailboxReader(socketPath: "/nonexistent/acpmux.sock", wake: RetryWake(owner: "AgentPaneRootSchedulerSweepTests"),
                                         clock: ContinuousClock(), policy: .firstConnect) { after in
            guard after == 0 else { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
            return AcpmuxMailboxPage(messages: [], nextCursor: 1)
        }
        let subscription = AcpmuxMailboxSubscription(mainWork: rig.work, workClass: .automation, owner: "test.held-reports")
        let queued = rig.work.postedCount(.automation)

        rig.input.pending = true
        let run = subscription.start(reader) { page in seen.values.append("\(page.nextCursor ?? 0)") }
        await Self.settle { rig.work.postedCount(.automation) > queued }
        #expect(rig.work.postedCount(.automation) == queued + 1, "the page did not reach the scheduler's automation queue")
        #expect(seen.values.isEmpty, "the agent's page applied ahead of the person's pending input")

        rig.input.pending = false
        rig.frame()
        await Self.settle { !seen.values.isEmpty }
        #expect(seen.values == ["1"], "the page did not apply once the input drained")
        #expect(rig.work.postedCount(.automation) == queued)
        subscription.stop()
        await run.value
        let row = try #require(rig.row("test.held-reports"), "the page hopped outside the scheduler")
        #expect(row.workClass == .automation)
    }

    // MARK: AgentPaneFramePacer (visible)

    /// A pane's next-turn delivery (a capped flush left frames) is one visible task of the pacer, not a main-queue job.
    @Test func aPanesNextTurnDeliveryIsAVisibleTask() async throws {
        let rig = Rig(), seen = Seen()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pacer = AgentPaneFramePacer(view: view, mainThread: AgentPaneMainThread(deadlines: MainDeadlineScheduler(work: rig.work),
                                                                                     appEvents: AppEvents(center: NotificationCenter()),
                                                                                     workspaceEvents: AppEvents(center: NotificationCenter())))
        defer { pacer.stop() }
        // Frames the page waits on, refused once (not delivered) and capped: the rest go on the next turn.
        pacer.schedule(urgent: true) {
            seen.calls += 1
            return AgentPaneFlush(delivered: false, more: seen.calls == 1)
        }
        #expect(seen.calls == 1)
        await Self.settle { rig.row("agent-pane.transport.next-turn") != nil }
        let row = try #require(rig.row("agent-pane.transport.next-turn"), "the next-turn delivery ran outside the scheduler")
        #expect(row.workClass == .visible)
    }
}

/// A scheduler whose frames the test fires by hand, on a clock it moves, with pending input it sets: a fake link kept
/// up by a frame client, so a task that yields on its turn waits for the next hand-fired frame.
@MainActor
private final class HeldRig {
    let input: HeldRigInput
    let work: MainWorkScheduler
    private let board: MainTaskBoard
    private let clock: HeldRigClock
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = HeldRigInput(), clock = HeldRigClock()
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 64, folding: .manual))
        self.input = input
        self.clock = clock
        self.board = board
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, board: board, uptimeNanos: clock.read),
                                             makeLink: { _ in HeldRigLink() })
        self.work = work
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    func row(_ owner: String) -> MainOwnerLedger.Owner? {
        board.ownerSnapshot().owners.first { $0.owner == owner }
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

/// A person's input the test holds pending.
@MainActor
private final class HeldRigInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class HeldRigClock {
    var now: UInt64 = 1_000_000_000
    // Strong: the scheduler's stall timer may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
}

@MainActor
private final class HeldRigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
