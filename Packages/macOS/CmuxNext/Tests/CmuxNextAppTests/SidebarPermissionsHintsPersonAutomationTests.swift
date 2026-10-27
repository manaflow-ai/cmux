import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextWakeups
import Foundation
import Testing

/// The person and automation cases of the p06-scheduler-319 sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9; the other classes are in SidebarPermissionsHintsSchedulerSweepTests), on a scheduler whose turns, frames
/// and pending input the test drives.
/// - Person (ChatsOpen.dispatch): a click's Open Chat applies acpmux's plan in one userBlocking task on the next turn,
///   with no frame, and that task's commit, not the click's own, closes the click's input response.
/// - Automation (ChatsOpen.dispatch): `cmux agent view` from the CLI without `focus` (`agentChat.view`) opens in an
///   automation task, and its workspace create may not change the view.
/// - Automation (AppDevToolsRelay.pageInstall): an agent's wait for a page install does not flush ahead of the
///   person's pending input; it flushes once the input drains.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarPermissionsHintsPersonAutomationTests {
    private static let chat = "claude-code:0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    /// What the opener's seams saw.
    @MainActor final class Seen {
        var viewChangeAllowed: Bool?
        var installed = false

        func created(viewChangeAllowed: Bool) { self.viewChangeAllowed = viewChangeAllowed }
    }

    /// Services on `rig`'s scheduler with no acpmux (showcase), and an opener whose plan is a terminal resume and
    /// whose create records the view permission it ran with.
    private static func opener(on rig: PostRig, seen: Seen) throws -> (AppServices, ChatsOpenCoordinator) {
        _ = NSApplication.shared
        let plan = try #require(AcpmuxChatOpenPlan(result: ["kind": "terminal", "cwd": "/tmp", "terminal": ["argv": ["claude", "--resume", "x"]]]))
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]), mainWork: rig.work)
        let opener = ChatsOpenCoordinator(services: services, plans: { _ in plan }, create: { _, _ in
            let allowed = ActionRunScope.viewChangeAllowed()
            await seen.created(viewChangeAllowed: allowed)
        })
        return (services, opener)
    }

    /// Lets off-main work and its hops to main run until `done`, for at most 5 s.
    private static func until(_ done: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < end { await Task.yield() }
    }

    // MARK: Person (ChatsOpen.dispatch)

    @Test func aPersonsOpenChatAppliesBeforeTheCommitAndAnswersTheClick() async throws {
        let rig = PostRig(), seen = Seen()
        defer { rig.stop() }
        let (services, opener) = try Self.opener(on: rig, seen: seen)
        let budget = rig.work.budget
        let (blocking, automation) = (rig.work.postedCount(.userBlocking), rig.work.postedCount(.automation))

        budget.noteDiscreteDispatch(began: true)
        opener.open(Self.chat, watch: true)
        budget.noteDiscreteInput(expectsFrame: true)
        budget.noteDiscreteDispatch(began: false)
        // The click's own turn commits before acpmux's plan comes back.
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(budget.isInputResponseOpen, "the click's own commit closed its response")

        await Self.until { rig.work.postedCount(.userBlocking) > blocking }
        #expect(rig.work.postedCount(.userBlocking) == blocking + 1, "the plan's reply was not one userBlocking task")
        #expect(rig.work.postedCount(.automation) == automation, "the person's open was posted as automation")
        rig.turns.runAll()
        await Self.until { seen.viewChangeAllowed != nil }
        #expect(seen.viewChangeAllowed == true, "the person's open did not run on the turn, or lost the view change")
        budget.noteRenderPass(nanos: 1_000_000)
        #expect(!budget.isInputResponseOpen, "the open's commit did not close the click's response")
        withExtendedLifetime(services) {}
    }

    // MARK: Automation (ChatsOpen.dispatch, `agentChat.view`)

    @Test func aCLIViewWithoutFocusOpensAsAutomationWithoutAViewChange() async throws {
        let rig = PostRig(), seen = Seen()
        defer { rig.stop() }
        let (services, opener) = try Self.opener(on: rig, seen: seen)
        let (blocking, automation) = (rig.work.postedCount(.userBlocking), rig.work.postedCount(.automation))

        // As the `agentChat.view` handler runs it for `cmux agent view <chat>`: no `focus`, and the action does not focus.
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
                opener.open(Self.chat, watch: true)
            }
        }
        #expect(tasks.count == 1, "the CLI does not wait for the open")
        await Self.until { rig.work.postedCount(.automation) > automation }
        #expect(rig.work.postedCount(.userBlocking) == blocking, "an agent's open took the person's class")

        rig.turns.runAll()
        await Self.until {
            rig.frame()
            return seen.viewChangeAllowed != nil
        }
        #expect(seen.viewChangeAllowed == false, "a CLI view without focus created its workspace with a view change")
        #expect(await tasks[0].value == nil)
        withExtendedLifetime(services) {}
    }

    // MARK: Automation (AppDevToolsRelay.pageInstall)

    @Test func aPageInstallWaitYieldsToPendingInputUntilItDrains() async {
        let rig = PostRig(), seen = Seen(), installs = PageInstallCounter()
        defer { rig.stop() }
        let waiting = Task { @MainActor in
            await AppDevToolsRelay.nextPageInstall(of: installs, on: rig.work)
            seen.installed = true
        }
        for _ in 0..<16 { await Task.yield() }
        let automation = rig.work.postedCount(.automation)

        rig.input.pending = true
        rig.work.causes.withCause(.automation) { installs.bump() }
        await Self.until { rig.work.postedCount(.automation) > automation }
        rig.frame()
        for _ in 0..<16 { await Task.yield() }
        #expect(!seen.installed, "the agent's wait resumed ahead of the person's pending input")
        #expect(rig.work.postedCount(.automation) > automation, "the wait's flush ran under pending input")

        rig.input.pending = false
        rig.frame()
        await waiting.value
        #expect(seen.installed, "the wait did not resume once the input drained")
    }
}

/// A scheduler on a fake link kept up by a frame client, so posts wait for hand-fired frames or for the turns the test
/// runs, with a clock the test moves and pending input it sets.
@MainActor
private final class PostRig {
    let input: PostRigInput
    let turns: PostRigTurns
    let work: MainWorkScheduler
    private let clock: PostRigClock
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = PostRigInput(), turns = PostRigTurns(), clock = PostRigClock()
        self.input = input
        self.turns = turns
        self.clock = clock
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                             performTurn: turns.perform) { _ in PostRigLink() }
        self.work = work
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.now += 17_000_000
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop() { keeper.deactivate() }
}

/// The scheduler's run loop turns, run only when the test says.
@MainActor
private final class PostRigTurns {
    private var queued: [@MainActor () -> Void] = []

    var perform: MainWorkScheduler.TurnPerformer { { [weak self] turn in self?.queued.append(turn) } }

    /// Runs the turns queued now.
    func runAll() {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
    }
}

/// A person's input the test holds pending.
@MainActor
private final class PostRigInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class PostRigClock {
    var now: UInt64 = 1_000_000_000
    // Strong: the scheduler's stall timer may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
}

@MainActor
private final class PostRigLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
