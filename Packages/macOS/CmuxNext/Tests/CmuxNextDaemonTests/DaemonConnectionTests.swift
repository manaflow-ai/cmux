import CmuxNextCompat
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

            let accepted = await connection.quietHandoff { true }
            #expect(accepted)
            #expect(connection.handoffGate.isHolding, "an accepted handoff did not hold new requests")
            await connection.close()
            #expect(!connection.handoffGate.isHolding, "close kept the hold")
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

/// ``QuietHandoffGate`` alone: the hold, the quiet wait, the queue and cancellation.
@Suite(.timeLimit(.minutes(1))) struct QuietHandoffGateTests {
    /// A gate whose parked waits arrive on `waits`, in order.
    private static func observedGate() -> (QuietHandoffGate, AsyncStream<QuietHandoffGate.Wait>.Iterator) {
        let (waits, continuation) = AsyncStream.makeStream(of: QuietHandoffGate.Wait.self)
        return (QuietHandoffGate(observe: { continuation.yield($0) }), waits.makeAsyncIterator())
    }

    @Test func aRequestWithNoHandoffEntersAtOnce() async {
        let gate = QuietHandoffGate()
        await gate.enter(passes: false)
        #expect(gate.requestsInFlight == 1)
        gate.leave()
        #expect(gate.requestsInFlight == 0)
    }

    @Test func aHeldRequestGoesOnWhenTheHoldEnds() async {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        let hold = await gate.beginHandoff()
        let request = Task {
            await gate.enter(passes: false)
            defer { gate.leave() }
            return gate.isHolding
        }
        let parked = await waits.next()
        #expect(parked == .request)
        #expect(gate.requestsInFlight == 0, "a held request was counted in flight")
        #expect(gate.release(hold))
        #expect(await request.value == false, "the request went on before the hold ended")
        #expect(gate.requestsInFlight == 0)
    }

    @Test func theHandoffsOwnRequestsPass() async {
        let gate = QuietHandoffGate()
        let hold = await gate.beginHandoff()
        await gate.enter(passes: true)
        #expect(gate.requestsInFlight == 1)
        gate.leave()
        gate.release(hold)
    }

    @Test func aHandoffWaitsUntilNoRequestIsInFlight() async {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        await gate.enter(passes: false)
        let handoff = Task { await gate.beginHandoff() }
        let parked = await waits.next()
        #expect(parked == .quiet)
        #expect(gate.isHolding, "the hold starts before the quiet wait")
        gate.leave()
        let hold = await handoff.value
        #expect(gate.holds(hold))
        gate.release(hold)
    }

    @Test func aCancelledHeldRequestGoesOnWhileTheHoldRuns() async {
        let (gate, stream) = Self.observedGate()
        var waits = stream
        let hold = await gate.beginHandoff()
        let request = Task {
            await gate.enter(passes: false)
            gate.leave()
        }
        let parked = await waits.next()
        #expect(parked == .request)
        request.cancel()
        await request.value
        #expect(gate.holds(hold), "a cancelled request ended the hold")
        #expect(gate.requestsInFlight == 0)
        gate.release(hold)
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
        #expect(gate.release(first))
        let next = await second.value
        #expect(next != first)
        #expect(!gate.release(first), "a stale release ended a hold")
        #expect(gate.holds(next))
        #expect(gate.release(next))
        #expect(!gate.isHolding)
    }

    /// Requests and handoffs at once from many tasks: no request is ever in flight while a handoff runs
    /// after its quiet wait, and every request gets through.
    @Test func noRequestRunsInsideAHandoff() async {
        let gate = QuietHandoffGate()
        let tally = Tally()
        let workers = 8, perWorker = 2_000, handoffs = 200
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    for _ in 0..<perWorker {
                        await gate.enter(passes: false)
                        if tally.handoffRunning.load(ordering: .sequentiallyConsistent) { tally.violations.wrappingAdd(1, ordering: .relaxed) }
                        tally.served.wrappingAdd(1, ordering: .relaxed)
                        gate.leave()
                    }
                }
            }
            group.addTask {
                for _ in 0..<handoffs {
                    let hold = await gate.beginHandoff()
                    tally.handoffRunning.store(true, ordering: .sequentiallyConsistent)
                    if gate.requestsInFlight != 0 { tally.violations.wrappingAdd(1, ordering: .relaxed) }
                    tally.handoffRunning.store(false, ordering: .sequentiallyConsistent)
                    gate.release(hold)
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
    let violations = Atomic<Int>(0)
    let served = Atomic<Int>(0)
}

extension DaemonConnection {
    /// Runs `body` on the connection's actor, holding it until `body` returns (the executor probe).
    fileprivate func whileIsolated(_ body: @Sendable () -> Bool) -> Bool {
        body()
    }
}
