import AppKit
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The CmuxNextSidebar/{Store,Model,Logic} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): one case per migrated owner class. The placeholder grace's deadline is in
/// SidebarSeedTests.
/// - Service: the rows and selection passes (`SidebarSameTurn`) apply their current value at once, a program burst in
///   one posted `visible` task, and a person's change in the input-response pass, before the commit (rules 2 and 3).
///   The pass's compute runs once per apply and never in a model's will-set.
/// - Automation: an agent's ask whose chat goes away answers No in one posted `automation` task, not in the change's
///   turn.
@MainActor @Suite(.serialized) struct SidebarStoreSchedulerSweepTests {
    @MainActor @Observable final class Source {
        var value = 0
        var present = true
    }

    @MainActor final class Recorder {
        var applied: [Int] = []
        /// Runs of the pass's compute: the rows pass walks every workspace, so a will-set must never run it.
        var computed = 0
    }

    // MARK: Service: the same-turn passes (R-obs)

    @Test func aPassAppliesNowThenOneBurstInOnePostedVisibleTaskAndAPersonsChangeBeforeTheCommit() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let sameTurn = SidebarSameTurn(view: SidebarView(model: SidebarModel()), mainWork: rig.work)
        let source = Source(), recorder = Recorder()
        sameTurn.observe(listsRows: true, {
            recorder.computed += 1
            return source.value
        }) { value in
            _ = source.present // the apply's reads are not followed
            recorder.applied.append(value)
        }
        #expect(recorder.applied == [0], "the pass did not apply its current value before it returned")
        #expect(recorder.computed == 1)

        let posted = rig.work.postedCount(.visible)
        source.value = 1
        source.value = 2
        source.value = 3
        #expect(recorder.applied == [0], "a program change applied in its own turn")
        #expect(recorder.computed == 1, "a program change's will-set ran the pass's compute")
        #expect(rig.work.postedCount(.visible) == posted + 1, "a burst of program changes posted more than one flush")
        rig.frame()
        #expect(recorder.applied == [0, 3], "the posted flush did not apply the burst's last value once")
        #expect(recorder.computed == 2, "the flush did not compute the burst exactly once")

        source.present = false
        rig.frame()
        #expect(recorder.computed == 2, "a change of what only the apply read ran the pass again")

        rig.work.causes.withCause(.person) { source.value = 4 }
        #expect(recorder.applied == [0, 3], "the person's change applied inside its will-set")
        #expect(recorder.computed == 2, "the person's will-set ran the pass's compute")
        #expect(rig.work.causes.flushPersonCaused() >= 1, "the person's change did not reach the input-response pass")
        #expect(recorder.applied == [0, 3, 4], "the person's change waited for a frame")
        #expect(recorder.computed == 3)
        rig.frame()
        #expect(recorder.computed == 3, "the posted flush computed again after the input-response pass")

        sameTurn.cancel()
        source.value = 5
        rig.frame()
        #expect(recorder.applied == [0, 3, 4], "a cancelled pass still applied")
        #expect(recorder.computed == 3, "a cancelled pass still computed")
    }

    // MARK: Automation: the asker watch and a cancelled caller (R-obs, R-hop)

    private static func card() -> SidebarNoticeCard { SidebarNoticeCard(id: "ask.test", title: "Make a Cloud machine?") }

    private static func waitForCard(_ asks: SidebarAsks) async {
        for _ in 0..<100 where asks.card == nil { await Task.yield() }
    }

    @Test func anAskWhoseChatGoesAwayAnswersNoInOnePostedAutomationTask() async {
        let rig = MainDeadlineRig()
        let asks = SidebarAsks(mainWork: rig.work)
        let source = Source()
        let answer = Task { await asks.ask(Self.card(), asker: "chat", present: { _ in source.present }) }
        await Self.waitForCard(asks)
        #expect(asks.card != nil, "the ask showed no card")

        let posted = rig.work.postedCount(.automation)
        source.present = false
        #expect(asks.card != nil, "the card went in the chat's own turn")
        #expect(rig.work.postedCount(.automation) == posted + 1, "the chat going away posted no automation task")
        rig.frame()
        #expect(asks.card == nil, "the posted task did not take the card away")
        #expect(await answer.value == false)
    }
}
