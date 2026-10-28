import AppKit
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Ghostty's tick and actions on the board (p06-scheduler-218): the app tick is the board task
/// `ghostty.tick`, input class while a key a terminal took waits for its frame and frame class
/// otherwise; a surface's state actions apply once per frame, latest wins, and a hidden surface's wait
/// for it to show, where they apply once; discrete actions keep their order after them.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct GhosttyTickClassTests {
    // MARK: The tick

    @Test func theTickIsABoardTaskThatShowsInTheOwners() {
        let rig = TickRig()
        let ticks = rig.ticks()
        var ran = 0
        ticks.run(posted: nil) { ran += 1 }
        ticks.run(posted: nil) { ran += 1 }

        #expect(ran == 2)
        #expect(rig.tickClasses == [.frame: 2], "with no key, every tick is frame work")
    }

    @Test func aTickRunsAsInputUntilTheTerminalKeysFrameThenAsFrame() {
        let rig = TickRig()
        let ticks = rig.ticks()
        ticks.noteTerminalKey()
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        ticks.run(posted: nil) {}
        ticks.run(posted: nil) {}
        #expect(ticks.classForTick() == .input, "the key's frame has not shown yet")

        // The key's result committed: its input response is closed.
        rig.work.budget.noteUserBlockingCommit()
        ticks.run(posted: nil) {}

        #expect(rig.tickClasses == [.input: 2, .frame: 1])
        #expect(ticks.classForTick() == .frame)
    }

    @Test func anInputResponseNoTerminalKeyOpenedLeavesTheTickInTheFrameClass() {
        let rig = TickRig()
        let ticks = rig.ticks()
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        ticks.run(posted: nil) {}

        #expect(rig.tickClasses == [.frame: 1], "a click elsewhere is not the terminal's input")
    }

    @Test func aTerminalKeyWhoseResponseReachedItsCapTicksAsFrame() {
        let rig = TickRig()
        let ticks = rig.ticks()
        ticks.noteTerminalKey()
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        rig.clock.now += 101_000_000
        ticks.run(posted: nil) {}

        #expect(rig.tickClasses == [.frame: 1], "an input response never stays open past its 100 ms cap")
    }

    /// A key whose frame no tick saw does not make a later click's response the terminal's.
    @Test func aLaterResponseNoTerminalKeyOpenedTicksAsFrameAfterAnUnseenKey() {
        let rig = TickRig()
        let ticks = rig.ticks()
        ticks.noteTerminalKey()
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        rig.work.budget.noteUserBlockingCommit()
        rig.clock.now += 200_000_000
        // A click on the sidebar opens a response of its own; no key reached the terminal since.
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        ticks.run(posted: nil) {}

        #expect(rig.tickClasses == [.frame: 1])
    }

    @Test func theRuntimesTickRunsOnTheBoardOnceAttached() {
        let rig = TickRig()
        let runtime = GhosttyRuntime()
        runtime.tick(posted: nil)
        #expect(rig.tickClasses.isEmpty, "before the composition root attaches it, a tick runs off the board")

        runtime.attach(to: rig.work)
        #expect(runtime.mainWork === rig.work)
        runtime.noteTerminalKey()
        rig.work.budget.noteDiscreteInput(expectsFrame: true)
        runtime.tick(posted: MainTaskPost(enqueueNanos: rig.clock.now))

        #expect(rig.tickClasses == [.input: 1])
    }

    // MARK: The actions

    @Test func aHundredTitlesInAFrameApplyOnce() {
        let rig = ActionRig(node: VisibilityNode(root: "tab", own: .visible))
        for index in 1...100 { #expect(rig.deliver(.setTitle("t\(index)"))) }
        #expect(rig.recorder.applied.isEmpty, "a title waits for the frame")

        rig.frame()

        #expect(rig.recorder.applied == ["title t100"])
        #expect(rig.mailbox.applies == 1)
        #expect(rig.mailbox.replaced == 99)
    }

    @Test func aHiddenSurfacesStateAppliesOnceWhenItShows() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let rig = ActionRig(node: node)
        for index in 1...100 { rig.deliver(.pwd("/d\(index)")) }

        rig.frame()
        rig.frame()
        #expect(rig.recorder.applied.isEmpty, "nobody sees the terminal: nothing applies")
        #expect(rig.mailbox.applies == 0)
        #expect(rig.mailbox.isHeld)
        #expect(!rig.hasClient, "a held mailbox keeps no frame client on its window's link")

        node.set(.visible)
        #expect(rig.recorder.applied.isEmpty, "it applies in the frame after the show, not inside the flip")
        rig.frame()

        #expect(rig.recorder.applied == ["pwd /d100"])
        #expect(rig.mailbox.applies == 1)
        #expect(!rig.mailbox.isScheduled)
        rig.frame()
        #expect(rig.mailbox.applies == 1)
    }

    /// The title shows outside the terminal (its tab, the sidebar, a remote tab's record): a hidden
    /// terminal's title applies at the next frame, after the held state Ghostty sent before it.
    @Test func aHiddenSurfacesTitleAppliesAtTheNextFrameAfterWhatWaitsBeforeIt() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let rig = ActionRig(node: node)
        rig.deliver(.pwd("/tmp"))
        rig.frame()
        #expect(rig.recorder.applied.isEmpty)
        #expect(rig.mailbox.isHeld)

        for index in 1...100 { rig.deliver(.setTitle("t\(index)")) }
        #expect(!rig.mailbox.isHeld, "a waiting title takes the pass off the hold")
        rig.frame()

        #expect(rig.recorder.applied == ["pwd /tmp", "title t100"])
        #expect(rig.mailbox.applies == 1)
        #expect(!rig.mailbox.isScheduled)

        rig.deliver(.pwd("/var"))
        rig.frame()
        #expect(rig.recorder.applied == ["pwd /tmp", "title t100"], "with no title waiting, the hold is back")
        #expect(rig.mailbox.isHeld)
    }

    @Test func aCapturedHiddenSurfaceAppliesAtItsFrame() {
        let node = VisibilityNode(root: "tab", own: .hidden)
        let rig = ActionRig(node: node)
        rig.deliver(.pwd("/seen"))
        let vote = node.captureVote(reason: "screenshot", stayHidden: true)
        rig.frame()

        #expect(rig.recorder.applied == ["pwd /seen"], "a capture sees the hidden terminal")
        withExtendedLifetime(vote) {}
    }

    @Test func aHiddenSurfacesDiscreteActionRunsAtOnceAfterTheStateSentBeforeIt() {
        let rig = ActionRig(node: VisibilityNode(root: "tab", own: .hidden))
        rig.deliver(.pwd("/before"))
        rig.deliver(.ringBell)
        rig.deliver(.pwd("/after"))
        rig.deliver(.commandFinished(TerminalCommandResult(exitCode: 0, duration: .seconds(1))))

        #expect(rig.recorder.applied == ["pwd /before", "bell", "pwd /after", "command"],
                "discrete actions keep their order, hidden or not")
        #expect(rig.mailbox.pendingCount == 0)
        #expect(!rig.mailbox.isScheduled)
    }

    @Test func aSurfaceMovedUnderAnotherNodeFollowsTheNewOne() {
        let hidden = VisibilityNode(root: "old tab", own: .hidden)
        let rig = ActionRig(node: hidden)
        rig.deliver(.pwd("/one"))
        rig.frame()
        #expect(rig.recorder.applied.isEmpty)

        rig.recorder.actionNode = VisibilityNode(root: "new tab", own: .visible)
        rig.deliver(.pwd("/two"))
        rig.frame()

        #expect(rig.recorder.applied == ["pwd /two"])
        hidden.set(.visible)
        rig.frame()
        #expect(rig.recorder.applied == ["pwd /two"], "the old node's client went with the move")
    }

    /// A held state applies when the bridge's waiting actions are flushed (a save at quit, a surface swap).
    @Test func aFlushAppliesWhatAHiddenSurfaceHolds() {
        let rig = ActionRig(node: VisibilityNode(root: "tab", own: .hidden))
        rig.deliver(.pwd("/held"))
        rig.frame()
        #expect(rig.mailbox.isHeld)

        rig.bridge.flushActions()

        #expect(rig.recorder.applied == ["pwd /held"])
        #expect(!rig.mailbox.isScheduled)
    }
}

/// A budget on a clock the test moves, on a scheduler with a fake link.
@MainActor
private final class TickRig {
    final class MovingClock {
        var now: UInt64 = 1_000_000_000
    }

    let clock: MovingClock
    let work: MainWorkScheduler

    init() {
        let clock = MovingClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now }), performTurn: { _ in }) { _ in
            TickTestLink()
        }
    }

    /// The tick on this rig's scheduler and clock.
    func ticks() -> GhosttyTickClass {
        let clock = clock
        return GhosttyTickClass(work: work, now: { clock.now })
    }

    /// The `ghostty.tick` tasks the board's ledger recorded, per class.
    var tickClasses: [MainWorkClass: Int] {
        var classes: [MainWorkClass: Int] = [:]
        for owner in work.board.ownerSnapshot().owners where owner.owner == GhosttyTickClass.owner {
            classes[owner.workClass, default: 0] += owner.tasks
        }
        return classes
    }
}

/// A surface bridge whose target records what reaches it and stands in a tab node of the test's.
@MainActor
private final class ActionRig {
    @MainActor final class Recorder: GhosttySurfaceTarget {
        let actionFrameScheduler: FrameScheduler
        var actionNode: VisibilityNode?
        private(set) var applied: [String] = []

        init(scheduler: FrameScheduler, node: VisibilityNode?) {
            actionFrameScheduler = scheduler
            actionNode = node
        }

        func applyAction(_ action: GhosttyAction) -> Bool {
            switch action {
            case .setTitle(let title): applied.append("title \(title)")
            case .pwd(let pwd): applied.append("pwd \(pwd)")
            case .ringBell: applied.append("bell")
            case .commandFinished: applied.append("command")
            default: applied.append("other")
            }
            return true
        }

        func handleHostAction(_ action: TerminalHostAction) -> Bool { true }
        func confirmClipboard(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {}
        func writeClipboard(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool) {}
        func surfaceRequestedClose() {}
    }

    let scheduler: FrameScheduler
    let recorder: Recorder
    let bridge: SurfaceBridge
    private var frames = 0

    init(node: VisibilityNode?) {
        scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in TickTestLink() }
        recorder = Recorder(scheduler: scheduler, node: node)
        // The surface's input goes nowhere: these tests read only its actions.
        let lane = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "GhosttyTickClassTests.input", qos: .utility)) { _, _ in .next })
        bridge = SurfaceBridge(input: TerminalInputSink(lane: lane, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()))
        bridge.target = recorder
    }

    var mailbox: GhosttyActionMailbox { bridge.actionMailbox }
    var hasClient: Bool { scheduler.activeClients.contains("terminal.actions") }

    /// `action` through the bridge, as Ghostty's `action_cb` hands it over.
    @discardableResult
    func deliver(_ action: GhosttyAction) -> Bool {
        bridge.deliver(action, runtime: nil)
    }

    /// One 120 Hz link frame.
    func frame() {
        frames += 1
        scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
    }
}

@MainActor
private final class TickTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
