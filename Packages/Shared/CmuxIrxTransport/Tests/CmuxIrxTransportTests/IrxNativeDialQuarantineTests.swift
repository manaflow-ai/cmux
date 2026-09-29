import CMUXMobileCore
import Testing
@testable import CmuxIrxTransport

@Suite struct IrxNativeDialQuarantineTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func retiredNativeDialsStayBoundedAndReleaseCapacity(cancelCaller: Bool) async throws {
        let first = try await IrxReconnectTestSession.make()
        let second = try await IrxReconnectTestSession.make()
        let recovered = try await IrxReconnectTestSession.make()
        let gates = [IrxReconnectDialGate(), IrxReconnectDialGate()]
        let dials = IrxControlledDialSequence(
            sessions: [first.session, second.session, recovered.session], gates: gates)
        let deadline = IrxDialTestClock()
        let retryClock = IrxDialTestClock()
        let engine = IrxPeerEngine(
            journal: IrxLiveTestSupport.journal(),
            clockNow: { retryClock.now },
            retrySleep: { try await retryClock.sleep(for: $0) },
            dialClock: deadline,
            dialOnce: { await dials.dial() })

        for gate in gates {
            let caller = Task {
                do {
                    _ = try await engine.ensureSession(explicit: true, trigger: "held-native")
                    return DiagnosticFailureKind.unknown
                } catch { return DiagnosticFailureKind.classify(error) }
            }
            await gate.waitUntilStarted()
            if cancelCaller {
                caller.cancel()
            } else {
                await deadline.waitUntilArmed()
                deadline.advance()
            }
            #expect(await caller.value == (cancelCaller ? .cancelled : .timedOut))
        }

        for _ in 0..<3 {
            do {
                _ = try await engine.ensureSession(explicit: true, trigger: "cleanup-full")
                Issue.record("Two unresolved native results must refuse further allocation")
            } catch {
                #expect(DiagnosticFailureKind.classify(error) == .admissionDenied,
                        "cleanup admission refusal is neither a timeout nor cancellation")
            }
        }
        let startsWhileFull = await dials.count
        #expect(startsWhileFull == 2, "retirement must not erase physical dial accounting")
        // Keep the expected-red implementation from leaking its held fixtures.
        guard startsWhileFull == 2 else {
            await engine.stop()
            for gate in gates { await gate.release() }
            await first.close(); await second.close(); await recovered.close()
            return
        }

        let states = await engine.states()
        await gates[0].release()
        _ = await first.session.connection.termination()
        // Releasing physical cleanup must re-arm the existing retry owner.
        await retryClock.waitUntilArmed()
        retryClock.advance()
        let ready = try await withIrxDeadline(.seconds(2), onTimeout: {}) {
            for await state in states {
                if case .ready = state { return true }
            }
            return false
        }
        #expect(ready == true)
        #expect(await dials.count == 3)
        #expect(await engine.currentSession()?.connection === recovered.session.connection)
        if ready == true { try await recovered.verifyRoundTrip() }
        await gates[1].release()
        _ = await second.session.connection.termination()
        #expect(await engine.currentSession()?.connection === recovered.session.connection)
        await engine.stop()
        await first.close(); await second.close(); await recovered.close()
    }
}
