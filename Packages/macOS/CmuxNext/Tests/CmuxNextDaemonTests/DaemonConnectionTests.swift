import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The connection's request path takes no turn on its actor (p05-ipc-091): `request` and `resourceRequest`
/// read the ready connection from a `Mutex` snapshot and pass the quiet-handoff gate with atomics. Before,
/// both were actor methods: every request waited for the actor, behind reconnect and handoff work.
@Suite(.timeLimit(.minutes(1))) struct DaemonConnectionTests {
    /// A python stand-in for cmux-tui on a bridge: answers `identify` and every other command with ok.
    private static func standInDaemon() -> DaemonConnection {
        let script = #"""
        import json, sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            result = {}
            if frame.get('cmd') == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'nonisolated-requests','capabilities':[]}
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        return DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-nonisolated-\(UUID().uuidString).sock", bridge: bridge),
                                configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
    }

    /// The executor probe: while the connection's actor is held, a request still gets its reply.
    @Test func aRequestIsAnsweredWhileTheConnectionsActorIsBusy() async throws {
        let connection = Self.standInDaemon()
        do {
            try await connection.start()
            // concurrency-allow: signalled from a pool task, waited on by the held actor below, never on main
            let answered = DispatchSemaphore(value: 0)
            let gotReply = await connection.whileIsolated {
                // Not on the actor: this task starts from the test's nonisolated closure.
                Task {
                    if (try? await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))) != nil { answered.signal() }
                }
                // concurrency-allow: the test holds the connection's actor on a pool thread (never main) to prove the request needs no actor turn
                return answered.wait(timeout: .now() + .seconds(5)) == .success
            }
            #expect(gotReply, "the request waited for the connection's actor")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    /// The handoff's own requests pass its hold; a refused handoff ends the hold at once; close ends an
    /// accepted one, and a request afterwards fails as not connected instead of waiting.
    @Test func aHandoffsOwnRequestsPassItsHoldAndCloseEndsTheHold() async throws {
        let connection = Self.standInDaemon()
        do {
            try await connection.start()
            let passed = await connection.quietHandoff({ () async -> Bool in
                (try? await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))) != nil
            }, accepted: { _ in false })
            #expect(passed, "the handoff's own request did not pass its hold")
            #expect(!connection.handoffGate.isHolding, "a refused handoff kept its hold")
            #expect(connection.handoffHoldStage.last?.end == .refused)

            let accepted = await connection.quietHandoff { true }
            #expect(accepted)
            #expect(connection.handoffGate.isHolding, "an accepted handoff did not hold new requests")
            await connection.close()
            #expect(!connection.handoffGate.isHolding, "close kept the hold")
            let stage = connection.handoffHoldStage
            #expect(stage.last?.end == .closed)
            #expect(stage.ends == [.refused: 1, .closed: 1])
            #expect(stage.running == nil)
            await #expect(throws: DaemonError.self) {
                try await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))
            }
            #expect(connection.handoffGate.requestsInFlight == 0)
        } catch {
            await connection.close()
            throw error
        }
    }
}

/// A terminal started while an accepted handoff waits for the next daemon gets the shell integration of the
/// daemon that carries it. The arguments are decided after the hold, from the ready connection the request
/// goes out on; decided before it, the request saw no ready connection and went out without them.
@Suite(.timeLimit(.minutes(1))) struct DaemonConnectionHandoffSpawnTests {
    /// A daemon that serves `terminal-shell-args-v1`. Its first process exits on `set-split-ratio` (the
    /// handoff's own request: the old daemon went away); the next process, the reconnect, answers
    /// `create-terminal` with the `shell_args` it got in `lifecycle`.
    private static let script = #"""
    import json, os, sys
    marker = sys.argv[1]
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        data = {}
        command = frame.get('cmd')
        if command == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'handoff-spawn-test', 'capabilities': ['terminal-shell-args-v1']}
        elif command == 'set-split-ratio' and not os.path.exists(marker):
            open(marker, 'w').close()
            os._exit(0)
        elif command == 'create-terminal':
            data = {'terminal_id': 't1', 'key': 'w1', 'replayed': False,
                    'lifecycle': '|'.join(frame.get('shell_args') or ['no shell args'])}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    @Test func aTerminalHeldThroughAHandoffGetsTheNextDaemonsShellArguments() async throws {
        // The hold limit and the reconnect wait on a clock that never moves: only `wake` reconnects.
        let clock = ManualClock()
        let marker = NSTemporaryDirectory() + "cmux-handoff-spawn-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let (reconnectParks, reconnectParked) = AsyncStream<Void>.makeStream()
        let wake = RetryWake(owner: "DaemonConnectionHandoffSpawnTests", probe: RetryWakeProbe(parked: { _ in reconnectParked.yield() }))
        let (gateWaits, gateWaited) = AsyncStream<QuietHandoffGate.Wait>.makeStream()
        var configuration = DaemonConnectionConfiguration(
            requiredCapabilities: [], retry: RetryPolicy(initial: .milliseconds(50), maximum: .seconds(1), timedRetries: 0),
            retryWake: wake, terminalEnvironment: nil)
        configuration.handoffWaits = { gateWaited.yield($0) }
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", Self.script, marker])
        let connection = DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-handoff-spawn-\(UUID().uuidString).sock", bridge: bridge),
                                          configuration: configuration, clock: clock)
        do {
            try await connection.start()
            let accepted = await connection.quietHandoff { () async -> Bool in
                _ = try? await connection.request(SetSplitRatioRequest(split: 1, ratio: 0.5))
                return true
            }
            #expect(accepted)
            // The old daemon is gone and the reconnect waits for `wake`: no ready connection while the hold runs.
            var parks = reconnectParks.makeAsyncIterator()
            _ = await parks.next()
            #expect(connection.admittedConnection == nil)
            #expect(connection.handoffGate.isHolding, "the accepted handoff's hold ended before the next daemon")

            let env = ["SHELL": "/usr/bin/nu", "GHOSTTY_SHELL_INTEGRATION_XDG_DIR": "/tmp/cmux-handoff-spawn-xdg"]
            let create = Task {
                try await connection.request(CreateTerminalRequest(workspace: .key("w1"), env: env, mutation: nil))
            }
            var waits = gateWaits.makeAsyncIterator()
            let parked = await waits.next()
            #expect(parked == .request, "the create did not wait out the hold")
            wake.fire()
            let created = try await create.value
            #expect(created.lifecycle == "--execute|use ghostty *", "the next daemon got the create without its shell arguments")
            let stage = connection.handoffHoldStage
            #expect(stage.last?.end == .ready, "the hold did not end with the next daemon ready")
            #expect(stage.last?.heldRequests == 1)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }
}

/// ``QuietHandoffGate`` alone: the hold, the quiet wait, the queue and cancellation.
@Suite(.timeLimit(.minutes(1))) struct QuietHandoffGateTests {
    /// A gate whose parked waits arrive on `waits`, in order.
    private static func observedGate() -> (QuietHandoffGate, AsyncStream<QuietHandoffGate.Wait>.Iterator) {
        let (waits, continuation) = AsyncStream.makeStream(of: QuietHandoffGate.Wait.self)
        return (QuietHandoffGate(observe: { continuation.yield($0) }), waits.makeAsyncIterator())
    }

    @Test func aRequestWithNoHandoffEntersAtOnce() async throws {
        let gate = QuietHandoffGate()
        try await gate.enter(passes: false)
        #expect(gate.requestsInFlight == 1)
        gate.leave()
        #expect(gate.requestsInFlight == 0)
    }

    @Test func aHeldRequestGoesOnWhenTheHoldEnds() async throws {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        let hold = await gate.beginHandoff()
        let request = Task {
            try await gate.enter(passes: false)
            defer { gate.leave() }
            return gate.isHolding
        }
        let parked = await waits.next()
        #expect(parked == .request)
        #expect(gate.requestsInFlight == 0, "a held request was counted in flight")
        #expect(gate.release(hold, end: .ready) != nil)
        #expect(try await request.value == false, "the request went on before the hold ended")
        #expect(gate.requestsInFlight == 0)
    }

    @Test func theHandoffsOwnRequestsPass() async throws {
        let gate = QuietHandoffGate()
        let hold = await gate.beginHandoff()
        try await gate.enter(passes: true)
        #expect(gate.requestsInFlight == 1)
        gate.leave()
        gate.release(hold, end: .ready)
    }

    @Test func aHandoffWaitsUntilNoRequestIsInFlight() async throws {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        try await gate.enter(passes: false)
        let handoff = Task { await gate.beginHandoff() }
        let parked = await waits.next()
        #expect(parked == .quiet)
        #expect(gate.isHolding, "the hold starts before the quiet wait")
        gate.leave()
        let hold = await handoff.value
        #expect(gate.holds(hold))
        gate.release(hold, end: .ready)
    }

    @Test func aCancelledHeldRequestGoesOnWhileTheHoldRuns() async {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        let hold = await gate.beginHandoff()
        let request = Task {
            try await gate.enter(passes: false)
            gate.leave()
        }
        let parked = await waits.next()
        #expect(parked == .request)
        request.cancel()
        if case .failure(let error) = await request.result { Issue.record("a cancelled held request failed: \(error)") }
        #expect(gate.holds(hold), "a cancelled request ended the hold")
        #expect(gate.requestsInFlight == 0)
        gate.release(hold, end: .ready)
    }

    /// A hold that ends at its limit fails the requests it parked, unsent, and records how long it held
    /// them and how it ended (the stage `debug.daemon` reports).
    @Test func aHoldAtItsLimitFailsItsRequestsUnsentAndIsMeasured() async throws {
        let clock = ManualClock()
        let (waitStream, continuation) = AsyncStream.makeStream(of: QuietHandoffGate.Wait.self)
        let gate = QuietHandoffGate(observe: { continuation.yield($0) }, elapsed: LineTransport.elapsedReader(clock))
        var waits = waitStream.makeAsyncIterator()
        let hold = await gate.beginHandoff()
        let request = Task {
            try await gate.enter(passes: false)
            gate.leave()
        }
        let parked = await waits.next()
        #expect(parked == .request)
        clock.advance(by: .seconds(3))
        #expect(gate.stage.running == DaemonConnection.HandoffHoldStage.Hold(end: nil, duration: .seconds(3), heldRequests: 1))
        let ended = gate.release(hold, end: .limit)
        #expect(ended == DaemonConnection.HandoffHoldStage.Hold(end: .limit, duration: .seconds(3), heldRequests: 1))
        await #expect(throws: DaemonError.handoffNotReady) { try await request.value }
        #expect(gate.requestsInFlight == 0, "a request failed at the limit was left counted in flight")
        let stage = gate.stage
        #expect(stage.ends == [.limit: 1])
        #expect(stage.holds == 1)
        #expect(stage.heldRequests == 1)
        #expect(stage.maxDuration == .seconds(3))
        #expect(stage.running == nil)
        // The hold is over: a new request enters at once.
        try await gate.enter(passes: false)
        gate.leave()
    }

    /// A second handoff waits for the first's hold; a late release of the first hold (its timer) does
    /// not end the second's.
    @Test func aSecondHandoffWaitsItsTurnAndAStaleReleaseKeepsItsHold() async {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        let first = await gate.beginHandoff()
        let second = Task { await gate.beginHandoff() }
        let parked = await waits.next()
        #expect(parked == .queue)
        #expect(gate.release(first, end: .ready) != nil)
        let next = await second.value
        #expect(next != first)
        #expect(gate.release(first, end: .limit) == nil, "a stale release ended a hold")
        #expect(gate.holds(next))
        #expect(gate.release(next, end: .ready) != nil)
        #expect(!gate.isHolding)
    }

    /// Requests and handoffs at once from many tasks: no request is past ``QuietHandoffGate/enter(passes:)``
    /// while a handoff runs after its quiet wait, and every request gets through. `admitted` counts only
    /// requests that returned from `enter`; the gate's own count also has a request about to park again.
    @Test func noRequestRunsInsideAHandoff() async {
        let gate = QuietHandoffGate()
        let tally = Tally()
        let workers = 8, perWorker = 2_000, handoffs = 200
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    for _ in 0..<perWorker {
                        // No hold here ends at its limit, so every enter returns.
                        guard (try? await gate.enter(passes: false)) != nil else { continue }
                        tally.admitted.wrappingAdd(1, ordering: .sequentiallyConsistent)
                        if tally.handoffRunning.load(ordering: .sequentiallyConsistent) { tally.violations.wrappingAdd(1, ordering: .relaxed) }
                        tally.served.wrappingAdd(1, ordering: .relaxed)
                        tally.admitted.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                        gate.leave()
                    }
                }
            }
            group.addTask {
                for _ in 0..<handoffs {
                    let hold = await gate.beginHandoff()
                    tally.handoffRunning.store(true, ordering: .sequentiallyConsistent)
                    if tally.admitted.load(ordering: .sequentiallyConsistent) != 0 { tally.violations.wrappingAdd(1, ordering: .relaxed) }
                    tally.handoffRunning.store(false, ordering: .sequentiallyConsistent)
                    gate.release(hold, end: .ready)
                    await Task.yield()
                }
            }
        }
        #expect(tally.violations.load(ordering: .relaxed) == 0)
        #expect(tally.served.load(ordering: .relaxed) == workers * perWorker)
        #expect(gate.requestsInFlight == 0)
        #expect(!gate.isHolding)
    }
}

/// The stress test's shared counters (a task cannot capture an `Atomic` itself).
private final class Tally: Sendable {
    let handoffRunning = Atomic<Bool>(false)
    /// Requests between their return from `enter` and their `leave`.
    let admitted = Atomic<Int>(0)
    let violations = Atomic<Int>(0)
    let served = Atomic<Int>(0)
}

extension DaemonConnection {
    /// Runs `body` on the connection's actor, holding it until `body` returns (the executor probe).
    fileprivate func whileIsolated(_ body: @Sendable () -> Bool) -> Bool {
        body()
    }
}
