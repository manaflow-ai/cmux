import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxNextWakeups
import Foundation
@testable import MessagesLabSidebar
import Testing

/// The CmuxNextApp/{Drag,HostPressure,TopPages} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): one case per migrated owner class. A person's tab move ends in one userBlocking task and
/// an agent's in one automation task, with the move's failure answered to the run; the forced host pressure level and
/// the Home page's rows are service observations (they apply on the scheduler's frame, and while the page hides);
/// the Home page's own node follows its hidden state.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct DragHostPressureTopPagesSweepTests {
    // MARK: Person and automation: a tab move's end (TabMoves.send)

    /// A person's move (a drag, no action run) is awaited off main and lands in one userBlocking task.
    @Test func aPersonsMoveLandsInOneUserBlockingTask() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let seen = DragSweepSeen()
        TabMoves.send("test.move", services: services, landed: { ok in
            seen.landed.append(ok)
            seen.classes.append(rig.deadlines.work.budget.board.running?.workClass)
        }) { nil }
        #expect(seen.landed.isEmpty, "the move landed in the drop's own turn, before its command was awaited")
        hostPressureSpin(until: { !seen.landed.isEmpty }, rig: rig)
        #expect(seen.landed == [true])
        #expect(seen.classes == [.userBlocking], "the person's move ended outside one userBlocking task")
        withExtendedLifetime(services) {}
    }

    /// An agent's or the CLI's move ends in one automation task (it yields to the person's input), and the command's
    /// failure is the run's answer.
    @Test func aCLIMovesFailureEndsInOneAutomationTaskAndAnswersTheRun() async {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let seen = DragSweepSeen()
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
                TabMoves.send("test.cliMove", services: services, landed: { ok in
                    seen.landed.append(ok)
                    seen.classes.append(rig.deadlines.work.budget.board.running?.workClass)
                }) { "the daemon refused the move" }
            }
        }
        hostPressureSpin(until: { !seen.landed.isEmpty }, rig: rig)
        #expect(seen.landed == [false])
        #expect(seen.classes == [.automation], "the CLI's move ended outside one automation task")
        guard let task = tasks.first else { Issue.record("the move reported no work to the capturing run"); return }
        let failure = await task.value
        #expect(failure?.message == "the daemon refused the move")
        withExtendedLifetime(services) {}
    }

    // MARK: Service observation: the forced host pressure level

    /// The forced level is a background service observation (host pressure is background work): a change applies on the
    /// scheduler's frame as one posted background task, not in the change's own turn.
    @Test func aForcedLevelChangeAppliesOnTheFrame() {
        let store = TunableStore(), rig = MainDeadlineRig()
        store.register(HostPressureTunables.all)
        store.activate(file: nil)
        let service = hostPressureTestService(store, rig: rig)
        #expect(service.level == .normal)
        _ = store.set(HostPressureTunables.force.key, HostPressureForce.critical.tunableValue)
        #expect(service.level == .normal, "the forced level applied in the change's own turn")
        #expect(rig.deadlines.work.postedCount(.background) > 0, "the forced level's flush is not a posted background task")
        rig.frame()
        #expect(service.level == .critical)
        service.stop()
    }

    // MARK: Hidden: the Home page (TopHomePageView)

    /// The page's node follows its hidden state (viewDidHide and viewDidUnhide only forward to it), and its rows are a
    /// service observation: a hidden page's list still takes a team that lands, on the next frame.
    @Test func aHiddenHomePageStillListsTheTeamThatLands() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let page = TopHomePageView(services: services, windowKey: { "sweep-317" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The window's node reads visible (the window is never ordered in), so the page's node follows only its own hide.
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = page
        defer { window.close() }
        #expect(page.visibility.node.isVisible, "the page's node is not visible in a visible window")
        page.isHidden = true
        #expect(!page.visibility.node.isVisible, "a hidden page's node stayed visible (viewDidHide does not reach it)")

        let ada = HomeContact(id: ParticipantID("user_ada"), name: "Ada Lovelace", source: .team)
        services.home.directory.teamMembers = [ada]
        let listed = { page.list.list.entries.map(\.id).contains(HomeSidebarView.teammateRowID(ada)) }
        for _ in 0..<50 where !listed() { rig.frame() }
        #expect(listed(), "a hidden page's rows did not take the team (the rows are a service observation)")

        page.isHidden = false
        #expect(page.visibility.node.isVisible, "the shown page's node stayed hidden")
    }
}

@MainActor
private final class DragSweepSeen {
    var landed: [Bool] = []
    var classes: [MainWorkClass?] = []
}
