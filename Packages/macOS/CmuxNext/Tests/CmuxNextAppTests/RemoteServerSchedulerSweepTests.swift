import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextServer
import CmuxNextWakeups
import Foundation
import Observation
import Testing
@testable import CmuxNextApp

/// The CmuxNextApp/{Remote,RemoteView,Server} sweep (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// rule 9): a person's pairing answer is one userBlocking task that needs no frame; an install's
/// step posted before the install ended never shows after it; a machine whose daemon connection was remade or replaced
/// is a new link value, so its browser status is read again. ServerReachAdmissionTests has the service observations,
/// the read's visible apply and the link file's automation yield.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteServerSchedulerSweepTests {
    // MARK: Person: CloudPairingSource

    /// A person's code lookup is asked off main; its answer reaches the panel in one userBlocking task on the turn it
    /// reaches main, with no frame fired (before the commit of the frame that shows it).
    @Test func aPairingLookupAnswersInOneUserBlockingTaskThatNeedsNoFrame() async {
        let rig = MainDeadlineRig(), seen = SweepSeen()
        let work = rig.deadlines.work
        let source = CloudPairingSource(inner: SweepServerSource(), call: { _, body in
            switch body["op"] as? String {
            case "team.policy.get": return ["value": ["team": "team_fixture"]]
            // No thumbprint: the key cannot be checked, which the panel is told.
            case "server.pair.preview": return ["value": ["code": "ABCD-EFGH"]]
            default: throw SweepError.unknownOp
            }
        }, account: { "fixture" }, mainWork: work)
        source.start { event in
            guard case .settled(let key, let reject) = event, key == "lookup-1" else { return }
            seen.workClass = work.budget.board.running?.workClass
            seen.reject = reject
        }
        source.send(ServerIntent(kind: .lookupCode("ABCD-EFGH"), key: "lookup-1"))
        await Self.settle(until: { seen.workClass != nil })
        #expect(seen.workClass == .userBlocking, "the person's pairing answer ran outside one userBlocking task")
        #expect(seen.reject != nil, "the unchecked key was not told")
        source.stop()
    }

    // MARK: SSH install steps

    /// An install step posted before the install ended (the step's visible task waits for a frame) does not show
    /// once the install cleared its step, and an older install's step never shows on a newer one.
    @Test func anInstallStepPostedBeforeTheInstallEndedDoesNotShowAfterIt() async throws {
        let rig = MainDeadlineRig()
        let work = rig.deadlines.work
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@install-phase.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-install-phase-unused")),
                                        environment: { [:] }, mainWork: work)
        defer { session.close() }
        let first = session.beginInstall()
        #expect(session.installPhase == .manifest)
        work.postFromAnyThread(.visible, owner: "test.installPhase") { session.showInstallStep(.restart, of: first) }
        await Self.settle(until: { work.postedCount(.visible) > 0 }, frames: nil)
        // The ssh step returned (or failed) before the posted step's frame.
        session.endInstall()
        rig.frame()
        #expect(work.postedCount(.visible) == 0)
        #expect(session.installPhase == nil, "a step posted before the install ended showed after it")

        let second = session.beginInstall()
        session.showInstallStep(.remoteDownload, of: first)
        #expect(session.installPhase == .manifest, "an ended install's step showed on the next install")
        session.showInstallStep(.upload, of: second)
        #expect(session.installPhase == .upload)
    }

    // MARK: MachineBrowserHosts

    /// The links observation's value names each machine's connection: a connection dropped and remade before one
    /// flush, or replaced by another, applies again (the status is read for the new connection); an unchanged
    /// connection does not.
    @Test func aRemadeOrReplacedConnectionAppliesTheLinksAgain() {
        let rig = MainDeadlineRig(), daemon = SweepDaemon(), log = SweepLog()
        daemon.connection = SweepConnection()
        let observation = ServiceObservation(.visible, owner: "test.links", on: rig.deadlines.work) {
            [MachineBrowserHosts.MachineLink(machine: "machine-1", connection: daemon.connection)]
        } apply: { links in
            log.applied.append(links)
        }
        #expect(log.applied.count == 1)
        daemon.connection = nil
        daemon.connection = SweepConnection()
        rig.frame()
        #expect(log.applied.count == 2, "a connection dropped and remade within one flush did not apply")
        daemon.connection = SweepConnection()
        rig.frame()
        #expect(log.applied.count == 3, "a replaced connection did not apply")
        rig.frame()
        #expect(log.applied.count == 3, "an unchanged connection applied again")
        observation.cancel()
        withExtendedLifetime(daemon) {}
    }

    /// Main run loop passes (where posts from other threads arrive), main-actor turns and, with a rig, one frame
    /// each, until `done` or 5 s. The caller expects `done` after it, so a wait that never ends fails its test.
    private static func settle(until done: () -> Bool, frames rig: MainDeadlineRig? = nil) async {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !done(), ContinuousClock.now < end {
            runMainLoopPass(for: 0.005)
            rig?.frame()
            await Task.yield()
        }
    }
}

private enum SweepError: Error {
    case unknownOp
}

@MainActor
private final class SweepSeen {
    var workClass: MainWorkClass?
    var reject: String?
}

@MainActor
private final class SweepLog {
    var applied: [[MachineBrowserHosts.MachineLink]] = []
}

/// A machine's daemon whose connection the test sets, observable as `DaemonService.connection` is.
@MainActor @Observable
private final class SweepDaemon {
    var connection: SweepConnection?
}

private final class SweepConnection {}

/// This Mac's own server status: nothing, the pairing intents never reach it.
private final class SweepServerSource: ServerSource {
    func start(_ sink: @escaping @MainActor (ServerSourceEvent) -> Void) {}
    func send(_ intent: ServerIntent) {}
    func stop() {}
}
