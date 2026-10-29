import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The CmuxNextApp/Handlers K-W sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9):
/// one case per migrated owner class. A person's Cmd-W ends in one userBlocking task that needs no frame; a CLI run's
/// completion keeps its daemon command scope; the waits end on their condition, their deadline or their task's cancel,
/// never by a poll, and a connect wait whose connection dropped waits again instead of telling a failure. The person
/// completion's commit and the automation yield are ActionClassedWorkTests' cases.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HandlersSchedulerSweepTests {
    // MARK: ObservedCondition (the remote, room, dock and group-close waits)

    /// The holds-now, later-frame and deadline cases are WindowsSchedulerSweepTests'; this is the cancel: the wait's
    /// task resumes and its timeout is disarmed.
    @Test func aCancelledWaitResumesItsTaskAndDisarmsItsDeadline() async {
        let rig = MainDeadlineRig(), flag = HandlersSweepFlag()
        let condition = ObservedCondition(owner: "test.cancel", .visible, on: rig.deadlines.work)
        let waiter = Task { await condition.until(timeout: .seconds(2), deadlines: rig.deadlines) { flag.isOn } }
        while !condition.isWaiting { await Task.yield() }
        #expect(rig.hasArmedWake)
        waiter.cancel()
        // The cancel posts the end from any thread: it reaches main on a run loop pass, then runs on a frame.
        Self.spin(until: { !condition.isWaiting }, rig: rig)
        await waiter.value
        #expect(!condition.isWaiting, "a cancelled wait kept its task suspended")
        #expect(!rig.hasArmedWake, "a cancelled wait left its timeout armed")
    }

    /// A task cancelled before it waits returns at once and arms nothing.
    @Test func aWaitInACancelledTaskReturnsAtOnce() async {
        let rig = MainDeadlineRig(), flag = HandlersSweepFlag()
        let condition = ObservedCondition(owner: "test.cancelledFirst", .visible, on: rig.deadlines.work)
        // A main-actor task starts only when this test suspends: it is cancelled before it waits.
        let waiter = Task { await condition.until(timeout: .seconds(2), deadlines: rig.deadlines) { flag.isOn } }
        waiter.cancel()
        await waiter.value
        #expect(!condition.isWaiting)
        #expect(!rig.hasArmedWake, "a cancelled task's wait armed its timeout")
    }

    /// NewChatPlacement's dock and focus waits: a tab that never lists ends the wait at ``MainPaneLayout/listLimit``
    /// with nil, so the dock frees the strip (`dockFinished`) instead of holding the chat out of it.
    @Test func aDockWaitForATabThatNeverListsEndsAtTheListLimit() async {
        let rig = MainDeadlineRig()
        let waiter = Task { await NewChatPlacement.listed("test.dock", on: rig.deadlines.work, deadlines: rig.deadlines) { () -> String? in nil } }
        while !rig.hasArmedWake { await Task.yield() }
        rig.fireAndRun()
        #expect(await waiter.value == nil)
        #expect(rig.elapsed >= 30, "the dock wait ended \(rig.elapsed) s in, before its 30 s bound")
    }

    // MARK: Remote connect wait (RemoteHandlers.showWhenConnected)

    /// The wait decides on the state it reads when its task runs: a connection that dropped while the machine still
    /// connects waits again; only a stop the person must fix is told.
    @Test func aConnectWaitWaitsAgainWhenItsConnectionDroppedWhileConnecting() {
        #expect(RemoteHandlers.connectOutcome(loaded: true, status: .connected) == .loaded)
        for status: SSHConnectionMachine.Status in [.reconnecting, .connecting, .unreachable("no route"), .failed("reset"), .installing] {
            #expect(RemoteHandlers.connectOutcome(loaded: false, status: status) == .stillConnecting, "\(status) was told as a failure")
        }
        for status: SSHConnectionMachine.Status in [.authFailed("denied"), .hostKeyUntrusted("changed"), .installFailed("no disk")] {
            #expect(RemoteHandlers.connectOutcome(loaded: false, status: status) == .stopped(tell: true))
        }
        #expect(RemoteHandlers.connectOutcome(loaded: false, status: .offline) == .stopped(tell: false))
    }

    // MARK: Person: Cmd-W (TabCloseGuard)

    /// A person's close of a live terminal asks the daemon off main, then closes in one userBlocking task that runs on
    /// the turn the answer reaches main, with no frame fired.
    @Test func aPersonsTerminalCloseIsOneUserBlockingTaskThatNeedsNoFrame() {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7_301)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let seen = HandlersSweepSeen()
        #expect(!TabCloseGuard.askedTerminals(closing: [tab], services: services).isEmpty, "the close warning does not apply")
        TabCloseGuard.close([tab], on: services.daemon, services: services, window: window) { _ in
            seen.closedIn.append(rig.deadlines.work.budget.board.running?.workClass)
        }
        #expect(TabCloseGuard.reading.contains(tab.id), "a live terminal's close skipped the daemon's read")
        Self.spin(until: { !seen.closedIn.isEmpty }, rig: nil)
        #expect(seen.closedIn == [.userBlocking], "the person's close ran outside one userBlocking task")
        #expect(!TabCloseGuard.reading.contains(tab.id))
        #expect(!TabCloseGuard.asking.contains(tab.id))
        withExtendedLifetime((services, window)) {}
    }

    // MARK: Automation: a CLI run's completion (ActionRouting's run locals)

    /// A CLI run without `focus`: its completion, posted outside the run's task tree, keeps the run's daemon command
    /// scope (its tickets and derived keys) and may not change the view.
    @Test func aCLIRunsCompletionKeepsItsDaemonCommandScope() async {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        ActionRouting.install(services)
        let scope = DaemonCommandScope.automation(idempotencyKey: "retry-1"), seen = HandlersSweepSeen()
        let tasks = services.registry.capturingWork {
            ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
                DaemonCommandScope.$current.withValue(scope) {
                    _ = services.registry.trackWork(owner: "test.cli", on: services.mainWork) {} then: { _ in
                        seen.scope = DaemonCommandScope.current
                        seen.viewChangeAllowed = ActionRunScope.viewChangeAllowed()
                        return nil
                    }
                }
            }
        }
        Self.spin(until: { seen.viewChangeAllowed != nil }, rig: rig)
        _ = await tasks.first?.value
        #expect(seen.scope === scope, "the completion lost the run's daemon command scope")
        #expect(seen.viewChangeAllowed == false, "a CLI run without focus changed the view from its completion")
        withExtendedLifetime(services) {}
    }

    /// Main run loop passes (where off-main posts arrive) and, with a rig, frames, until `done` or 5 s.
    private static func spin(until done: () -> Bool, rig: MainDeadlineRig?) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            rig?.frame()
        }
    }
}

@MainActor @Observable
private final class HandlersSweepFlag {
    var isOn = false
}

@MainActor
private final class HandlersSweepSeen {
    var closedIn: [MainWorkClass?] = []
    var scope: DaemonCommandScope?
    var viewChangeAllowed: Bool?
}
