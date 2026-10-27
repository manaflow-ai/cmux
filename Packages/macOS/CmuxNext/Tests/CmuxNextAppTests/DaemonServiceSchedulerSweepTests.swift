import AppKit
import CmuxNextActions
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// Rule 9 of plans/cmux-next/chrome-parity/p06-scheduler.md for the owners file group p06-scheduler-339 migrated in
/// CmuxNextDaemonService and CmuxNextDaemonRecovery: one case per owner class. A view apply (the recovery controls)
/// does nothing while its window is hidden and catches up on show; a reply posts in its cause's class (a person's:
/// userBlocking, an agent's: automation); and the service's deadlines are MainDeadlines on the app's queue, which
/// the rig fires.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DaemonServiceSchedulerSweepTests {
    /// What a posted body saw: the class of the task that ran it.
    final class Ran {
        var workClass: MainWorkClass??
    }

    /// Set when a waiting task's wait returned.
    final class Done {
        var value = false
    }

    private static func service(_ rig: MainDeadlineRig) -> DaemonService {
        DaemonService(mainWork: rig.work, deadlines: rig.deadlines, appEvents: AppEvents(center: NotificationCenter()))
    }

    /// Runs main run loop turns and the rig's frames until `done` holds (bounded): a post from another thread
    /// reaches main on a run loop turn, then runs in a frame.
    private static func turnsAndFrames(_ rig: MainDeadlineRig, until done: () -> Bool) async {
        for _ in 0..<50 where !done() {
            await drainMainTurns(rounds: 1)
            rig.frame()
        }
    }

    private static func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        return view.subviews.lazy.compactMap { button(identifier, in: $0) }.first
    }

    // MARK: View apply: hidden, then shown

    /// DaemonRecoveryControls follow the recovery through a VisibleObservation on the window's node: while the
    /// window is hidden, the stuck owner's Restart offer changes the model only; the button shows when the
    /// window does.
    @Test func theRecoveryControlsApplyNothingWhileHiddenAndCatchUpOnShow() async throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let node = VisibilityNode(root: "test.window", own: .hidden)
        let recovery = DaemonRecovery()
        let controls = DaemonRecoveryControls(recovery: recovery, node: node, on: rig.work)
        controls.isOffered = true
        let launcher = DaemonLauncher(work: BackgroundWork(label: "test.recovery-controls"),
                                      configuration: .init(binary: URL(fileURLWithPath: "/nonexistent/cmux-tui"), session: "cn-recovery-sweep"),
                                      environment: { [:] })
        recovery.attach(launcher, wake: RetryWake(owner: "test.recovery-controls"), on: rig.work)
        let restart = try #require(Self.button("daemon.restart", in: controls))
        #expect(restart.isHidden, "Restart shows before any ensure failed")

        launcher.ensureOutcome.note(DaemonError.timedOut("server ensure")) // a stuck owner's failure
        await Self.turnsAndFrames(rig) { recovery.offersRestart }
        try #require(recovery.offersRestart, "the ensure outcome's visible task never ran")
        rig.frame()
        #expect(restart.isHidden, "a hidden window's controls applied the offer")

        node.set(.visible)
        await Self.turnsAndFrames(rig) { !restart.isHidden }
        #expect(!restart.isHidden, "the controls did not catch up when the window showed")
    }

    // MARK: Replies in the cause's class

    /// whenApplied's rest is one task in the class of the run that asked: a person's run's is userBlocking (the
    /// rest of their action), an agent's or the CLI's is automation.
    @Test(arguments: [(ActionOrigin.user, MainWorkClass.userBlocking), (ActionOrigin.cli, MainWorkClass.automation)])
    func whenAppliedPostsInTheClassOfTheRunsCause(_ origin: ActionOrigin, _ expected: MainWorkClass) async {
        let rig = MainDeadlineRig()
        let service = Self.service(rig)
        // Never started: its event sequence is nil, so the rest runs as soon as its task does.
        service.connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-when-applied.sock"))
        let ran = Ran()
        ActionRunScope.$current.withValue(ActionRunScope(origin: origin, allowsViewChange: false)) {
            service.whenApplied(.generate()) { ran.workClass = .some(rig.work.budget.board.running?.workClass) }
        }
        #expect(ran.workClass == nil, "the rest ran in the caller's turn")
        await Self.turnsAndFrames(rig) { ran.workClass != nil }
        #expect(ran.workClass == .some(expected), "the rest ran in \(String(describing: ran.workClass)), not \(expected)")
    }

    // MARK: Deadlines on the app's queue

    /// The first connection's deadline is a visible MainDeadline on the app's deadlines: the window shows the
    /// failure when the rig fires it, not before.
    @Test func theStartupDeadlineShowsTheFailureWhenTheRigFiresIt() async {
        let rig = MainDeadlineRig()
        let service = Self.service(rig)
        service.startupDeadline = .seconds(10)
        service.start { DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-startup-deadline.sock")) }
        defer { service.shutdownConnection() }
        #expect(rig.hasArmedWake, "the startup deadline is not a wake on the app's deadline queue")
        #expect(service.startup == .connecting)
        rig.fireAndRun()
        #expect(service.startup.isUnavailable, "the startup deadline's visible task did not show the failure")
    }

    /// The update restart's successor wait is an ObservedCondition bounded by a MainDeadline: with no successor,
    /// it ends with nil when the rig fires the bound.
    @Test func theUpdateRestartsWaitEndsAtItsBound() async {
        let rig = MainDeadlineRig()
        let service = Self.service(rig)
        let previous = DaemonIdentity(pid: 10, generation: "before-update")
        service.store.noteHandshake(previous)
        let done = Done()
        let wait = Task {
            let next = await service.successor(of: previous, within: .seconds(30))
            done.value = true
            return next
        }
        for _ in 0..<200 where !rig.hasArmedWake { await Task.yield() }
        #expect(rig.hasArmedWake, "the restart's bound is not a MainDeadline on the app's queue")
        await Self.turnsAndFrames(rig) { done.value }
        #expect(!done.value, "the wait ended before its bound with no successor")
        rig.fireAndRun()
        await Self.turnsAndFrames(rig) { done.value }
        #expect(await wait.value == nil, "the bound did not end the wait")
    }

    /// The successor's handshake ends the wait in one userBlocking re-read, before its bound.
    @Test func theUpdateRestartsWaitEndsOnTheSuccessorsHandshake() async {
        let rig = MainDeadlineRig()
        let service = Self.service(rig)
        let previous = DaemonIdentity(pid: 10, generation: "before-update")
        service.store.noteHandshake(previous)
        let done = Done()
        let wait = Task {
            let next = await service.successor(of: previous, within: .seconds(30))
            done.value = true
            return next
        }
        for _ in 0..<200 where !rig.hasArmedWake { await Task.yield() }
        let next = DaemonIdentity(pid: 11, generation: "after-update")
        service.store.noteHandshake(next)
        #expect(rig.work.postedCount(.userBlocking) > 0, "the handshake posted no userBlocking re-read")
        await Self.turnsAndFrames(rig) { done.value }
        #expect(await wait.value == next, "the successor's handshake did not end the wait")
        #expect(!rig.hasArmedWake, "the ended wait left its bound armed")
    }
}
