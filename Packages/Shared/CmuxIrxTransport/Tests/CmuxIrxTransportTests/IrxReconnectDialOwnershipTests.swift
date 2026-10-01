import CMUXMobileCore
import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

@Suite struct IrxReconnectDialOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func cancellingEngineWaiterReachesTheNativeHandshake() async throws {
        let server = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let client = try await IrxLiveTestSupport.bindLoopback(seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let nativeResult = AsyncStream<DiagnosticFailureKind>.makeStream()
        let engine = IrxPeerEngine(journal: IrxLiveTestSupport.journal()) {
            do {
                _ = try await client.connect(addr: IrxLiveTestSupport.loopbackAddr(of: server), alpn: IrxProtocol().alpnData)
                nativeResult.continuation.yield(.unknown)
                throw IrxConnectionError.closed(nil)
            } catch {
                nativeResult.continuation.yield(DiagnosticFailureKind.classify(error))
                throw error
            }
        }
        let caller = Task { try? await engine.ensureSession(trigger: "native-handshake") }
        // Receipt of an incoming handshake proves that the native dial started.
        // Deliberately leave it unaccepted until after cancellation.
        let incoming = try #require(await server.acceptNext())
        caller.cancel()
        #expect(await caller.value == nil)
        let result = try await withIrxDeadline(.seconds(2), onTimeout: {}) {
            var iterator = nativeResult.stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(result == .cancelled)
        _ = incoming
        await engine.stop()
        try await client.close()
        try await server.close()
        nativeResult.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineQuarantinesLateSuccessAndNextAttemptConnects() async throws {
        let stalled = try await IrxReconnectTestSession.make()
        let recovered = try await IrxReconnectTestSession.make()
        let sequence = IrxReconnectDialSequence(stalled: stalled, recovered: recovered)
        let deadline = IrxDialTestClock()
        let engine = IrxPeerEngine(
            config: .init(initialBackoff: .seconds(60), maxBackoff: .seconds(60)),
            journal: IrxLiveTestSupport.journal(),
            dialClock: deadline,
            dialOnce: { try await sequence.dial() }
        )
        let first = Task {
            do { _ = try await engine.ensureSession(trigger: "deadline"); return DiagnosticFailureKind.unknown }
            catch { return DiagnosticFailureKind.classify(error) }
        }
        await sequence.gate.waitUntilStarted()
        await deadline.waitUntilArmed()
        deadline.advance()
        #expect(await first.value == .timedOut)
        #expect(await engine.currentState != .connecting)
        // The first operation still owns its native result, and ignores cancellation.
        // A retry must connect without releasing it first.
        let next = try await engine.ensureSession(explicit: true, trigger: "retry")
        #expect(next.admit.session == recovered.session.admit.session)
        #expect(await sequence.count == 2)
        try await recovered.verifyRoundTrip()
        await sequence.gate.release()
        _ = await stalled.session.connection.termination()
        #expect(await engine.currentSession()?.admit.session == next.admit.session)
        try await recovered.verifyRoundTrip()
        await engine.stop()
        await stalled.close()
        await recovered.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func scheduledRetryDoesNotCancelItsOwnDialWaiter() async throws {
        let recovered = try await IrxReconnectTestSession.make()
        let sequence = IrxReconnectDialSequence(stalled: recovered, recovered: recovered, failFirst: true)
        let retryClock = IrxDialTestClock()
        let engine = IrxPeerEngine(journal: IrxLiveTestSupport.journal(),
                                  retrySleep: { delay in try await retryClock.sleep(for: delay) },
                                  dialOnce: { try await sequence.dial() })
        _ = try? await engine.ensureSession(trigger: "fails-once")
        await retryClock.waitUntilArmed()
        retryClock.advance()
        await sequence.gate.waitUntilStarted()
        await sequence.gate.release()
        let states = await engine.states()
        let ready = try await withIrxDeadline(.seconds(2), onTimeout: {}) {
            for await state in states {
                if case .ready = state { return true }
            }
            return false
        }
        #expect(ready == true)
        #expect(await sequence.count == 2)
        if ready == true { try await recovered.verifyRoundTrip() }
        await engine.stop()
        await recovered.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundStopsPendingDialAndDefersTheNextOne() async throws {
        let gate = IrxReconnectDialGate()
        let engine = IrxPeerEngine(journal: IrxLiveTestSupport.journal()) {
            await gate.wait()
            throw IrxConnectionError.closed(nil)
        }
        let first = Task { try? await engine.ensureSession(trigger: "launch") }
        await gate.waitUntilStarted()
        await engine.setApplicationActive(false)
        #expect(await first.value == nil)
        do {
            _ = try await engine.ensureSession(explicit: true, trigger: "background")
            Issue.record("A background request must not start a dial")
        } catch is CancellationError {} catch { Issue.record("Unexpected failure: \(error)") }
        #expect(await gate.starts == 1)
        #expect(await engine.currentState != .connecting)
        await gate.release()
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingLastWaiterReleasesHungPeerDial() async throws {
        let gate = IrxReconnectDialGate()
        let engine = IrxPeerEngine(
            journal: IrxJournal(subsystem: "test", category: "dial-ownership", journalFileURL: nil)
        ) {
            await gate.wait()
            throw IrxConnectionError.closed(nil)
        }
        let caller = Task {
            do {
                _ = try await engine.ensureSession(trigger: "first")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await gate.waitUntilStarted()
        caller.cancel()
        let returned = try await withIrxDeadline(.seconds(1), onTimeout: {}) {
            await caller.value
        }
        #expect(returned == true, "cancellation must return before the native dial is released")
        #expect(await engine.currentState != .connecting)
        await gate.release()
        _ = await caller.value
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func closingControlTransportReleasesHungEstablishment() async throws {
        let gate = IrxReconnectDialGate()
        let transport = IrxControlByteTransport(closeCode: .explicitRedial) {
            await gate.wait()
            throw IrxConnectionError.closed(nil)
        }
        let caller = Task {
            do {
                try await transport.connect()
                return false
            } catch {
                return true
            }
        }
        await gate.waitUntilStarted()
        await transport.close()
        let returned = try await withIrxDeadline(.seconds(1), onTimeout: {}) {
            await caller.value
        }
        #expect(returned == true, "close must settle the caller while native establishment is still hung")
        await gate.release()
        _ = await caller.value
    }
}
