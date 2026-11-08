@testable import CmuxNextCloud
import Testing

/// The carrier serve lifecycle as a reducer (``ServeMachine``): each test drives events and checks the state and
/// the exact effects. No process runs; the executor's smoke tests are in ``CloudCarrierDialTests``.
@Suite struct CloudCarrierServeMachineTests {
    typealias M = ServeMachine
    static let path = "/tmp/x/cmux-link-0123456789ab.sock"
    static let closed = CloudLinkError.disconnected(reason: "closed")
    static func env(_ token: String) -> [String: String] { ["CMUX_CLOUD_ACCESS_TOKEN": token] }

    // MARK: - Machines in each state (child 1 is the first launch's)

    static func idle() -> M { M(socket: path) }

    static func claiming() -> M {
        var machine = idle()
        _ = machine.reduce(.connect(1, keepRefusal: false))
        return machine
    }

    static func awaitingToken() -> M {
        var machine = claiming()
        _ = machine.reduce(.socketClaimed(1))
        return machine
    }

    static func spawning() -> M {
        var machine = awaitingToken()
        _ = machine.reduce(.tokenRead(1, read: 1, .ok(env("t-1"))))
        _ = machine.reduce(.spawned(child: 1, failure: nil))
        return machine
    }

    static func ready() -> M {
        var machine = spawning()
        _ = machine.reduce(.readyLine(child: 1, socket: path, policy: nil))
        return machine
    }

    /// A ready child that stopped taking stdin while connect 2 waited: draining child 1 at epoch 3.
    static func draining() -> M {
        var machine = ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        _ = machine.reduce(.tokenRead(1, read: 2, .ok(env("t-2"))))
        _ = machine.reduce(.tokenWritten(child: 1, token: "t-2", ok: false))
        return machine
    }

    /// A launch that failed on a bad ready line: its child 1 is still exiting.
    static func idleWithAliveChild() -> M {
        var machine = spawning()
        _ = machine.reduce(.readyLine(child: 1, socket: "/tmp/elsewhere.sock", policy: nil))
        return machine
    }

    static func everyState() -> [(String, M)] {
        [("idle", idle()), ("claiming", claiming()), ("awaitingToken", awaitingToken()), ("spawning", spawning()),
         ("ready", ready()), ("draining", draining()), ("idle with an exiting child", idleWithAliveChild())]
    }

    // MARK: - Table rows

    @Test func idleConnectClaimsThenReadsToken() {
        var machine = Self.idle()
        #expect(machine.reduce(.connect(1, keepRefusal: false)) == [.claimSocket(1)])
        #expect(machine.state == .claiming(1))
        #expect(machine.reduce(.socketClaimed(1)) == [.readToken(1, read: 1)])
        #expect(machine.state == .awaitingToken(1, read: 1))
        #expect(machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("t-1")))) == [.spawn(child: 1, environment: Self.env("t-1"))])
        #expect(machine.state == .spawning(1, child: 1, sentToken: "t-1"))
        #expect(machine.reduce(.spawned(child: 1, failure: nil)) == [.hold(child: 1), .armReadyDeadline(1)])
    }

    @Test func connectsWhileLaunchingJoinOneLaunch() {
        var machine = Self.idle()
        var effects = machine.reduce(.connect(1, keepRefusal: false))
        effects += machine.reduce(.connect(2, keepRefusal: false))
        effects += machine.reduce(.socketClaimed(1))
        effects += machine.reduce(.connect(3, keepRefusal: true))
        effects += machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("t-1"))))
        effects += machine.reduce(.connect(4, keepRefusal: false))
        effects += machine.reduce(.spawned(child: 1, failure: nil))
        effects += machine.reduce(.readyLine(child: 1, socket: Self.path, policy: nil))
        #expect(effects.filter { if case .spawn = $0 { true } else { false } }.count == 1)
        #expect(effects.last == .resume([1, 2, 3, 4], .success(Self.path)))
    }

    @Test func readyLineResumesWaitersAndArmsRefresh() {
        var machine = Self.spawning()
        #expect(machine.reduce(.readyLine(child: 1, socket: Self.path, policy: nil))
            == [.cancelReadyDeadline, .armRefresh(1, token: "t-1"), .resume([1], .success(Self.path))])
        #expect(machine.state == .ready(1, child: 1, M.Ready(sentToken: "t-1")))
        #expect(machine.refusal == nil)
        #expect(machine.answer == nil, "a new child has answered nothing")
    }

    @Test func readyLineForAnotherSocketFailsAndDrains() {
        var machine = Self.spawning()
        let error = CloudLinkError.invalidAnswer("served another socket")
        #expect(machine.reduce(.readyLine(child: 1, socket: "/tmp/elsewhere.sock", policy: nil))
            == [.cancelReadyDeadline, .closeStdin(child: 1), .release(child: 1), .resume([1], .failure(error))])
        #expect(machine.state == .idle(lastEnd: error, alive: 1))
        // The next connect waits for that child's exit before it claims the socket.
        #expect(machine.reduce(.connect(2, keepRefusal: false)) == [])
        #expect(machine.state == .draining(3, child: 1))
        #expect(machine.reduce(.childExit(child: 1, code: 0)) == [.claimSocket(3)])
        // A failed socket check is the same path with the check's refusal.
        var checked = Self.spawning()
        let unsafe = CloudLinkError.unsafeSocket("group-writable")
        #expect(checked.reduce(.readyLine(child: 1, socket: Self.path, policy: unsafe)).last == .resume([1], .failure(unsafe)))
    }

    @Test func okLineBeforeReadyIsInvalidAnswer() {
        var machine = Self.spawning()
        #expect(machine.reduce(.okLine(child: 1, vmk: "owner")).last == .resume([1], .failure(.invalidAnswer("no ready line"))))
    }

    @Test func refusalBeforeReadyMapsStartErrors() {
        let cases: [(String, String?, CloudLinkError)] = [
            ("bad_request", "Unix socket path \(Self.path) is already leased", CloudCarrierDial.socketTaken),
            ("ticket", "no credential", .failed(code: "ticket", message: "ticket: no credential")),
            ("handshake", nil, .failed(code: "handshake", message: "")),
        ]
        for (code, detail, error) in cases {
            var machine = Self.spawning()
            #expect(machine.reduce(.refusalLine(child: 1, code: code, detail: detail)).last == .resume([1], .failure(error)), "\(code)")
            #expect(machine.refusal == error)
        }
    }

    @Test func stderrEndBeforeAnyLineIsHelperNotRunning() {
        var machine = Self.spawning()
        let error = CloudLinkError.helperNotRunning(reason: "dyld: missing symbol")
        #expect(machine.reduce(.stderrEnded(child: 1, stderr: "dyld: missing symbol")).last == .resume([1], .failure(error)))
        #expect(machine.reduce(.childExit(child: 1, code: 134)) == [])
        #expect(machine.state == .idle(lastEnd: error, alive: nil))
    }

    @Test func readyDeadlineClosesTheChild() {
        var machine = Self.spawning()
        #expect(machine.reduce(.readyDeadline(1))
            == [.cancelReadyDeadline, .closeStdin(child: 1), .release(child: 1), .resume([1], .failure(M.noReadyLine))])
    }

    @Test func spawnFailureLeavesNoChild() {
        var machine = Self.awaitingToken()
        _ = machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("t-1"))))
        let error = CloudLinkError.disconnected(reason: "cmux carrier serve did not start: no file")
        #expect(machine.reduce(.spawned(child: 1, failure: error)) == [.resume([1], .failure(error))])
        #expect(machine.state == .idle(lastEnd: error, alive: nil))
        #expect(machine.reduce(.connect(2, keepRefusal: false)) == [.claimSocket(2)], "the next launch waits on no child")
    }

    @Test func connectWhileReadyWritesAFreshTokenThenAnswers() {
        var machine = Self.ready()
        #expect(machine.reduce(.connect(2, keepRefusal: false)) == [.readToken(1, read: 2)])
        #expect(machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-2")))) == [.writeToken(child: 1, token: "t-2")])
        #expect(machine.reduce(.tokenWritten(child: 1, token: "t-2", ok: true)) == [.resume([2], .success(Self.path)), .armRefresh(1, token: "t-2")])
        #expect(machine.state == .ready(1, child: 1, M.Ready(sentToken: "t-2")))
    }

    @Test func connectWhileReadySameTokenWritesNothing() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        #expect(machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-1")))) == [.resume([2], .success(Self.path)), .armRefresh(1, token: "t-1")])
    }

    @Test func twoConnectsWhileReadyShareOneTokenRead() {
        var machine = Self.ready()
        #expect(machine.reduce(.connect(2, keepRefusal: false)) == [.readToken(1, read: 2)])
        #expect(machine.reduce(.connect(3, keepRefusal: true)) == [])
        _ = machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-2"))))
        #expect(machine.reduce(.tokenWritten(child: 1, token: "t-2", ok: true)).first == .resume([2, 3], .success(Self.path)))
    }

    @Test func refreshDueReadsAndWritesOnlyWhileReady() {
        var machine = Self.ready()
        #expect(machine.reduce(.refreshDue(1)) == [.readToken(1, read: 2)])
        #expect(machine.reduce(.refreshDue(1)) == [], "one read at a time")
        #expect(machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-2")))) == [.writeToken(child: 1, token: "t-2")])
        #expect(machine.reduce(.tokenWritten(child: 1, token: "t-2", ok: true)) == [.armRefresh(1, token: "t-2")])
        for (name, state) in Self.everyState() where !state.isReady {
            var other = state
            #expect(other.reduce(.refreshDue(other.epoch)) == [], "\(name)")
        }
    }

    @Test func okLineSetsAnswerAndPublishes() {
        var machine = Self.ready()
        #expect(machine.reduce(.okLine(child: 1, vmk: "owner")) == [.publish(.owner)])
        #expect(machine.answer == .owner)
        #expect(machine.reduce(.okLine(child: 1, vmk: "team")) == [.publish(.team)])
        #expect(machine.answer == .team)
    }

    @Test func okLineWithoutVmkIsUnknown() {
        var machine = Self.ready()
        _ = machine.reduce(.okLine(child: 1, vmk: "owner"))
        #expect(machine.reduce(.okLine(child: 1, vmk: nil)) == [.publish(.unknown)], "a line without vmk is never owner")
        #expect(machine.answer == .unknown)
    }

    @Test func refusalWhileReadyIsReportedUntilNextConnect() {
        var machine = Self.ready()
        #expect(machine.reduce(.refusalLine(child: 1, code: "parked_timeout", detail: nil)) == [])
        #expect(machine.refusal == .notUp(state: "parked_timeout"))
        #expect(machine.reduce(.refusalLine(child: 1, code: "bad_request", detail: "token line")) == [])
        #expect(machine.refusal == .notUp(state: "parked_timeout"), "a refused stdin line is not a refused connection")
        _ = machine.reduce(.connect(2, keepRefusal: false))
        #expect(machine.refusal == nil)
    }

    @Test func keepingRefusalDoesNotClearIt() {
        var machine = Self.ready()
        _ = machine.reduce(.refusalLine(child: 1, code: "relay", detail: nil))
        _ = machine.reduce(.connect(2, keepRefusal: true))
        #expect(machine.refusal == .disconnected(reason: "relay"))
    }

    @Test func childExitWhileReadyGoesIdleWithExitedRefusal() {
        var machine = Self.ready()
        #expect(machine.reduce(.childExit(child: 1, code: 0)) == [.cancelRefresh, .release(child: 1)])
        #expect(machine.state == .idle(lastEnd: M.exited, alive: nil))
        #expect(machine.refusal == .helperNotRunning(reason: "cmux carrier serve exited"))
        // The listener failing for good names itself, not only the exit.
        var listener = Self.ready()
        _ = listener.reduce(.refusalLine(child: 1, code: "socket", detail: "accept failed"))
        _ = listener.reduce(.childExit(child: 1, code: 6))
        #expect(listener.refusal == .helperNotRunning(reason: "cmux carrier serve stopped listening: accept failed"))
    }

    @Test func childExitWithPendingConnectsRelaunches() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        #expect(machine.reduce(.childExit(child: 1, code: 0)) == [.cancelRefresh, .release(child: 1), .claimSocket(3)])
        #expect(machine.state == .claiming(3))
        #expect(machine.waiters == [2])
        #expect(machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-2")))) == [], "the old child's read is dropped")
    }

    @Test func writeFailedIsTreatedAsExit() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        _ = machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("t-2"))))
        #expect(machine.reduce(.tokenWritten(child: 1, token: "t-2", ok: false)) == [.cancelRefresh, .closeStdin(child: 1), .release(child: 1)])
        #expect(machine.state == .draining(3, child: 1), "the relaunch waits for the old child's exit")
        #expect(machine.reduce(.childExit(child: 1, code: 0)) == [.claimSocket(3)])
    }

    @Test func stopFromEachStateIsTerminal() {
        let expected: [String: [M.Effect]] = [
            "idle": [],
            "claiming": [.resume([1], .failure(Self.closed))],
            "awaitingToken": [.resume([1], .failure(Self.closed))],
            "spawning": [.cancelReadyDeadline, .closeStdin(child: 1), .release(child: 1), .resume([1], .failure(Self.closed)), .armStopDeadline(child: 1)],
            "ready": [.cancelRefresh, .closeStdin(child: 1), .release(child: 1), .armStopDeadline(child: 1)],
            "draining": [.closeStdin(child: 1), .release(child: 1), .resume([2], .failure(Self.closed)), .armStopDeadline(child: 1)],
            "idle with an exiting child": [.closeStdin(child: 1), .release(child: 1), .armStopDeadline(child: 1)],
        ]
        for (name, state) in Self.everyState() {
            var machine = state
            let child = machine.child
            #expect(machine.reduce(.stop) == expected[name], "\(name)")
            #expect(machine.state == (child.map { M.State.stopping(child: $0, .closed) } ?? M.State.stopped(.closed)), "\(name)")
            #expect(machine.waiters.isEmpty, "\(name)")
            #expect(machine.refusal == Self.closed, "\(name)")
            #expect(machine.reduce(.stop) == [], "\(name): a second stop does nothing")
            #expect(machine.reduce(.accountEnded) == [], "\(name)")
        }
    }

    @Test func connectAfterStopFailsWithoutEffects() {
        for (name, state) in Self.everyState() {
            var machine = state
            _ = machine.reduce(.stop)
            let after = machine.state
            #expect(machine.reduce(.connect(9, keepRefusal: false)) == [.resume([9], .failure(Self.closed))], "\(name)")
            #expect(machine.reduce(.connect(10, keepRefusal: true)) == [.resume([10], .failure(Self.closed))], "\(name)")
            #expect(machine.state == after, "\(name)")
        }
    }

    @Test func stoppingEscalatesToTerminateAtDeadline() {
        var machine = Self.ready()
        _ = machine.reduce(.stop)
        #expect(machine.reduce(.stopDeadline(child: 1)) == [.terminate(child: 1)])
        #expect(machine.reduce(.childExit(child: 1, code: 15)) == [])
        #expect(machine.state == .stopped(.closed))
        #expect(machine.reduce(.stopDeadline(child: 1)) == [], "no SIGTERM after the exit")
    }

    /// Every result event of an older epoch, or of a child that is not the current one, changes nothing.
    @Test func everyResultEventOfAnOldEpochIsDropped() {
        var stopped = Self.ready()
        _ = stopped.reduce(.stop)
        for (name, state) in Self.everyState() + [("stopping", stopped)] {
            let old = state.epoch &- 1
            let other = state.epoch &+ 50
            let events: [M.Event] = [
                .socketClaimed(old), .tokenRead(old, read: 1, .ok(Self.env("x"))), .tokenRead(old, read: 2, .fenced),
                .tokenRead(old, read: 1, .failed(.unsupported)), .spawned(child: other, failure: .unsupported),
                .heldResult(child: other, held: false), .readyLine(child: other, socket: Self.path, policy: nil),
                .okLine(child: other, vmk: "owner"), .refusalLine(child: other, code: "socket", detail: nil),
                .stderrEnded(child: other, stderr: ""), .readyDeadline(old), .childExit(child: other, code: 0),
                .refreshDue(old), .tokenWritten(child: other, token: "x", ok: false), .stopDeadline(child: other),
            ]
            for event in events {
                var machine = state
                #expect(machine.reduce(event) == [], "\(name): \(event)")
                #expect(machine.state == state.state && machine.epoch == state.epoch && machine.waiters == state.waiters, "\(name): \(event)")
            }
            // A stale successful spawn is the one exception: its child is closed and reaped.
            var machine = state
            #expect(machine.reduce(.spawned(child: other, failure: nil)) == [.closeStdin(child: other), .terminateAfterGrace(child: other)], "\(name)")
            #expect(machine.state == state.state, "\(name)")
        }
    }

    @Test func heldResultNilInSpawningStops() {
        var machine = Self.spawning()
        #expect(machine.reduce(.heldResult(child: 1, held: true)) == [])
        #expect(machine.reduce(.heldResult(child: 1, held: false))
            == [.cancelReadyDeadline, .closeStdin(child: 1), .release(child: 1), .resume([1], .failure(Self.closed)), .armStopDeadline(child: 1)])
        #expect(machine.state == .stopping(child: 1, .accountEnded))
    }

    @Test func tokenReadFencedFromAnyPhaseStops() {
        var launching = Self.awaitingToken()
        #expect(launching.reduce(.tokenRead(1, read: 1, .fenced)) == [.resume([1], .failure(Self.closed))])
        #expect(launching.state == .stopped(.accountEnded))
        var ready = Self.ready()
        _ = ready.reduce(.refreshDue(1))
        _ = ready.reduce(.tokenRead(1, read: 2, .fenced))
        #expect(ready.state == .stopping(child: 1, .accountEnded))
    }

    // MARK: - Regressions of #37210's review rounds, and the gaps the model found

    @Test func r4_okLineFromAPreviousChildIsIgnored() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        _ = machine.reduce(.childExit(child: 1, code: 0))
        _ = machine.reduce(.socketClaimed(3))
        _ = machine.reduce(.tokenRead(3, read: 3, .ok(Self.env("t-2"))))
        _ = machine.reduce(.spawned(child: 3, failure: nil))
        _ = machine.reduce(.readyLine(child: 3, socket: Self.path, policy: nil))
        #expect(machine.reduce(.okLine(child: 1, vmk: "owner")) == [])
        #expect(machine.answer == nil)
    }

    @Test func r4_failedTokenLookupKeepsTheReadyChild() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        #expect(machine.reduce(.tokenRead(1, read: 2, .failed(.unsupported))) == [.resume([2], .success(Self.path)), .armRefresh(1, token: "t-1")])
        #expect(machine.isReady)
    }

    @Test func r5_stopWhileAwaitingTokenSpawnsNothing() {
        var machine = Self.awaitingToken()
        _ = machine.reduce(.stop)
        #expect(machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("old-account")))) == [])
        #expect(machine.state == .stopped(.closed))
    }

    @Test func r5_stopWhileDrainingSpawnsNothing() {
        var machine = Self.draining()
        _ = machine.reduce(.stop)
        #expect(machine.reduce(.childExit(child: 1, code: 0)) == [])
        #expect(machine.reduce(.socketClaimed(3)) == [])
        #expect(machine.state == .stopped(.closed))
    }

    @Test func astraF2_failedRunDoesNotBlockNextLaunch() {
        var machine = Self.awaitingToken()
        _ = machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("t-1"))))
        _ = machine.reduce(.spawned(child: 1, failure: .disconnected(reason: "cmux carrier serve did not start")))
        let effects = machine.reduce(.connect(2, keepRefusal: false))
        #expect(effects == [.claimSocket(2)])
        #expect(machine.state == .claiming(2))
    }

    @Test func r6_accountEndStopsServeInEveryPhase() {
        for (name, state) in Self.everyState() {
            var machine = state
            _ = machine.reduce(.accountEnded)
            #expect(machine.isTerminal, "\(name)")
            for event in [M.Event.tokenRead(state.epoch, read: 1, .ok(Self.env("new-account"))), .tokenRead(state.epoch, read: 2, .ok(Self.env("new-account")))] {
                let effects = machine.reduce(event)
                #expect(!effects.contains { if case .writeToken = $0 { true } else if case .spawn = $0 { true } else { false } }, "\(name)")
            }
        }
    }

    @Test func r6_policyStopIsTerminalAgainstRelayAsk() {
        var machine = Self.ready()
        _ = machine.reduce(.stop)
        #expect(machine.reduce(.connect(5, keepRefusal: true)) == [.resume([5], .failure(Self.closed))])
    }

    @Test func r7_refreshAfterAccountEndWritesNoToken() {
        var machine = Self.ready()
        _ = machine.reduce(.refreshDue(1))
        _ = machine.reduce(.accountEnded)
        #expect(machine.reduce(.tokenRead(1, read: 2, .ok(Self.env("new-account")))) == [])
    }

    @Test func own_fencedFailureHandsOutNoSocket() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        let effects = machine.reduce(.tokenRead(1, read: 2, .fenced))
        #expect(effects.contains(.resume([2], .failure(Self.closed))))
        #expect(!effects.contains { if case .resume(_, .success) = $0 { true } else { false } })
    }

    @Test func own_launchRacingAccountEndIsClosed() {
        var machine = Self.spawning()
        #expect(machine.reduce(.heldResult(child: 1, held: false)).contains(.resume([1], .failure(Self.closed))))
        #expect(machine.reduce(.readyLine(child: 1, socket: Self.path, policy: nil)) == [])
        #expect(machine.state == .stopping(child: 1, .accountEnded))
    }

    @Test func f2_connectAwaitingTokenJoinsInFlightLaunch() {
        var machine = Self.awaitingToken()
        #expect(machine.reduce(.connect(2, keepRefusal: false)) == [])
        #expect(machine.reduce(.tokenRead(1, read: 1, .ok(Self.env("t-1")))) == [.spawn(child: 1, environment: Self.env("t-1"))])
        #expect(machine.waiters == [1, 2])
    }

    @Test func p1_stopThenConnectSpawnsNothing() {
        var machine = Self.idle()
        _ = machine.reduce(.stop)
        #expect(machine.reduce(.connect(1, keepRefusal: false)) == [.resume([1], .failure(Self.closed))])
    }

    @Test func p2_oldChildsRefusalDoesNotEndNewLink() {
        var machine = Self.ready()
        _ = machine.reduce(.connect(2, keepRefusal: false))
        _ = machine.reduce(.childExit(child: 1, code: 6))
        _ = machine.reduce(.socketClaimed(3))
        _ = machine.reduce(.tokenRead(3, read: 3, .ok(Self.env("t-2"))))
        _ = machine.reduce(.spawned(child: 3, failure: nil))
        _ = machine.reduce(.readyLine(child: 3, socket: Self.path, policy: nil))
        #expect(machine.reduce(.refusalLine(child: 1, code: "socket", detail: "accept failed")) == [])
        #expect(machine.refusal == nil)
    }
}
