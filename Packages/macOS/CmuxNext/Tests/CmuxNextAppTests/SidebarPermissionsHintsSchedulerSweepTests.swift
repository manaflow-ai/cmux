import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextOnboarding
@testable import CmuxNextServer
import CmuxNextWakeups
import Foundation
import Testing

/// The CmuxNextApp/{Permissions,ComputerUse,RightSidebar,BrowserHost,AgentRecents,DeepLinks,Settings,SidebarSections,Hints}
/// sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case per migrated owner
/// class, on a rig whose wakes and frames the test fires.
/// - VisibleObservation: the Machines section renders nothing while hidden and renders once in the show turn.
/// - ServiceObservation and AppEvents: Computer Use Setup reads the grants again on the distributed Accessibility
///   trust notice, with no view on screen.
/// - MainDeadline: a helper that does not answer is read again when the classed retry deadline fires, never before.
/// - MainDeadline (userBlocking): hint mode's page query answers with what came by its deadline, once; a cancelled
///   query answers nothing.
/// The person and automation classes (Open Chat, the DevTools relay's page-install wait) are in
/// SidebarPermissionsHintsPersonAutomationTests.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarPermissionsHintsSchedulerSweepTests {
    // MARK: VisibleObservation (MachineSectionHostView)

    @Test func aHiddenMachinesSectionRendersNothingAndRendersOnceOnShow() throws {
        let rig = MainDeadlineRig()
        let machines = MachineRegistry(local: DaemonService()), health = MachineHealthStore()
        let view = MachineSectionHostView(machines: machines, health: health, registry: ActionRegistry(),
                                          mainWork: rig.deadlines.work)
        // In no window: the view's node is under its hidden off-window root. The first rows apply at once.
        let local = try #require(view.model.rows.first)
        #expect(local.health == nil)

        health.record(local.id, HostReport(name: "mac", host: "mac", ok: false, steps: []))
        rig.frame()
        #expect(view.model.rows.first?.health == nil, "a hidden Machines section rendered the machine's check")

        try view.visibilityNode.attach(to: VisibilityNode(root: "test.window", own: .visible))
        #expect(view.model.rows.first?.health == .failing, "the Machines section did not render the check in the show turn")
    }

    // MARK: ServiceObservation, AppEvents and MainDeadline (ComputerUseSetup)

    /// Counts the grant reads (the read runs off main; the count is kept on main).
    @MainActor private final class Reads {
        var count = 0
        var answer: ComputerUseSetup.Read = .noAnswer

        func next() -> ComputerUseSetup.Read {
            count += 1
            return answer
        }
    }

    private static func setup(_ reads: Reads, rig: MainDeadlineRig, distributed: NotificationCenter) -> ComputerUseSetup {
        ComputerUseSetup(
            inputs: { ComputerUseSetup.Inputs(disabledByPolicy: false, enabled: true, helper: .running(1)) },
            configuration: { AgentActivitySocketSource.Configuration(socketPath: "/tmp/cmux-test-none.sock", machineName: "test") },
            read: { _ in await reads.next() },
            resolveHelper: { _ in nil },
            appEvents: AppEvents(center: NotificationCenter()),
            distributedEvents: AppEvents(center: distributed),
            deadlines: rig.deadlines, work: BackgroundWork())
    }

    /// Runs frames (the posted replies) until `done` holds.
    private static func frames(_ rig: MainDeadlineRig, until done: () -> Bool) async {
        while !done() {
            rig.frame()
            await Task.yield()
        }
    }

    @Test func aHelperThatDoesNotAnswerIsReadAgainWhenTheRetryDeadlineFiresNotBefore() async {
        let rig = MainDeadlineRig(), reads = Reads()
        let setup = Self.setup(reads, rig: rig, distributed: NotificationCenter())
        setup.start()
        await Self.frames(rig) { reads.count == 1 && rig.hasArmedWake }
        #expect(setup.phase == .starting, "a helper that did not answer is not reported as starting")

        for _ in 0..<5 { rig.frame() }
        await Task.yield()
        #expect(reads.count == 1, "the grants were read again before the retry deadline fired")

        rig.fireAndRun()
        await Self.frames(rig) { reads.count == 2 }
        #expect(reads.count == 2, "the retry deadline did not read the grants again")
    }

    @Test func theAccessibilityTrustNoticeReadsTheGrantsAgainWithNothingOnScreen() async {
        let rig = MainDeadlineRig(), reads = Reads(), distributed = NotificationCenter()
        reads.answer = .answered(ComputerUsePermissions(accessibility: false, screenRecording: true), helper: nil)
        let setup = Self.setup(reads, rig: rig, distributed: distributed)
        setup.start()
        await Self.frames(rig) { setup.phase == .ready }
        #expect(reads.count == 1)

        reads.answer = .answered(ComputerUsePermissions(accessibility: true, screenRecording: true), helper: nil)
        distributed.post(name: ComputerUseSetup.accessibilityTrustChanged, object: nil)
        await Self.frames(rig) { setup.permissions.accessibility }
        #expect(reads.count == 2, "the trust notice did not read the grants once")
    }

    // MARK: MainDeadline, userBlocking (PageCollection)

    private static let target = WindowHintTargets.Target(rect: CGRect(x: 0, y: 0, width: 20, height: 20), role: "web", title: "Open")

    @Test func aPageQueryAnswersWithWhatCameByItsDeadlineOnce() {
        let rig = MainDeadlineRig()
        var answers: [[WindowHintTargets.Target]] = []
        let query = PageCollection(count: 2, within: WindowHintTargets.pageDeadline, deadlines: rig.deadlines) {
            answers.append($0)
        }
        query.answer(0, [Self.target])
        rig.frame()
        #expect(answers.isEmpty, "the query answered before every page or its deadline")
        #expect(rig.hasArmedWake, "the query armed no deadline")

        rig.fireAndRun()
        #expect(answers == [[Self.target]], "the deadline did not answer with the page that came")
        query.answer(1, [Self.target])
        #expect(answers.count == 1, "a late page answered the query again")
    }

    @Test func aCancelledPageQueryAnswersNothing() {
        let rig = MainDeadlineRig()
        var answered = false
        let query = PageCollection(count: 1, within: WindowHintTargets.pageDeadline, deadlines: rig.deadlines) { _ in
            answered = true
        }
        query.cancel()
        rig.fireAndRun()
        query.answer(0, [Self.target])
        #expect(!answered, "a cancelled query answered")
    }
}
