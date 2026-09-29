import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite struct IrxReconnectDialOwnershipTests {
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
