import AppKit
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Observation
import Testing

/// The CmuxNextSidebar/{Store,Model,Logic} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// p06-scheduler-329, rule 9): one case per migrated owner class. The placeholder grace's deadline is in
/// SidebarSeedTests.
/// - Service: the rows and selection passes (`SidebarSameTurn`) apply their current value at once, a program burst in
///   one posted `visible` task, and a person's change in the input-response pass, before the commit (rules 2 and 3).
/// - Automation: an agent's ask whose chat goes away answers No in one posted `automation` task, not in the change's
///   turn.
@MainActor @Suite(.serialized) struct SidebarStoreSchedulerSweepTests {
    @MainActor @Observable final class Source {
        var value = 0
        var present = true
    }

    @MainActor final class Recorder {
        var applied: [Int] = []
    }

    // MARK: Service: the same-turn passes (R-obs)

    @Test func aPassAppliesNowThenOneBurstInOnePostedVisibleTaskAndAPersonsChangeBeforeTheCommit() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let sameTurn = SidebarSameTurn(view: SidebarView(model: SidebarModel()), mainWork: rig.work)
        let source = Source(), recorder = Recorder()
        sameTurn.observe({ source.value }) { recorder.applied.append($0) }
        #expect(recorder.applied == [0], "the pass did not apply its current value before it returned")

        let posted = rig.work.postedCount(.visible)
        source.value = 1
        source.value = 2
        #expect(recorder.applied == [0], "a program change applied in its own turn")
        #expect(rig.work.postedCount(.visible) == posted + 1, "a burst of program changes posted more than one flush")
        rig.frame()
        #expect(recorder.applied == [0, 2], "the posted flush did not apply the burst's last value once")

        rig.work.causes.withCause(.person) { source.value = 3 }
        #expect(recorder.applied == [0, 2], "the person's change applied inside its will-set")
        #expect(rig.work.causes.flushPersonCaused() >= 1, "the person's change did not reach the input-response pass")
        #expect(recorder.applied == [0, 2, 3], "the person's change waited for a frame")

        sameTurn.cancel()
        source.value = 4
        rig.frame()
        #expect(recorder.applied == [0, 2, 3], "a cancelled pass still applied")
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
