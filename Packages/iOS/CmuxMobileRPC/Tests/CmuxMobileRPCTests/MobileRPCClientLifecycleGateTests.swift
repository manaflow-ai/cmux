import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileRPCClientLifecycleGateTests {
    @Test
    func retirementInsideFactoryRejectsAndOwnsLateTransportCleanup() async {
        let gate = MobileRPCClientLifecycleGate()
        let transport = SuspendedLifecycleCloseTransport()

        #expect(throws: MobileShellConnectionError.self) {
            _ = try gate.makeTransport {
                // This would deadlock if the synchronous factory ran while the
                // lifecycle critical region was held.
                gate.retire()
                return transport
            }
        }

        await transport.waitUntilCloseStarted()
        let cleanup = Task {
            await gate.waitForRetiredTransportDisposals()
        }
        await transport.releaseClose()
        await cleanup.value

        #expect(await transport.didFinishClose())
    }

    @Test
    func retiredGateRejectsWithoutInvokingFactory() {
        let gate = MobileRPCClientLifecycleGate()
        let transport = SuspendedLifecycleCloseTransport()
        var invokedFactory = false
        gate.retire()

        #expect(throws: MobileShellConnectionError.self) {
            _ = try gate.makeTransport {
                invokedFactory = true
                return transport
            }
        }

        #expect(!invokedFactory)
    }

    @Test
    func retirementDuringArtifactOpenClosesTheStaleLane() async throws {
        let gate = MobileRPCClientLifecycleGate()
        let connection = RecordingArtifactLaneConnection()
        let admission = try gate.beginArtifactLaneAdmission()

        gate.retire()

        do {
            _ = try await gate.finishArtifactLaneAdmission(
                admission,
                connection: connection
            )
            Issue.record("stale artifact lane should be rejected")
        } catch MobileShellConnectionError.connectionClosed {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(await connection.closeCount() == 1)
    }

    @Test
    func retiredGateRejectsArtifactOpenBeforeProviderInvocation() {
        let gate = MobileRPCClientLifecycleGate()
        gate.retire()

        do {
            _ = try gate.beginArtifactLaneAdmission()
            Issue.record("retired gate should reject artifact admission")
        } catch MobileShellConnectionError.connectionClosed {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private actor RecordingArtifactLaneConnection: MobileArtifactLaneConnection {
    private var observedCloseCount = 0

    func receive(maximumByteCount _: Int) async throws -> Data? { nil }

    func close() async {
        observedCloseCount += 1
    }

    func closeCount() -> Int { observedCloseCount }
}

private actor SuspendedLifecycleCloseTransport: CmxByteTransport {
    private var closeStarted = false
    private var closeFinished = false
    private var closeReleased = false
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect() async throws {}
    func receive() async throws -> Data? { nil }
    func send(_: Data) async throws {}

    func close() async {
        closeStarted = true
        let startWaiters = closeStartWaiters
        closeStartWaiters.removeAll()
        for waiter in startWaiters { waiter.resume() }

        if !closeReleased {
            await withCheckedContinuation { closeReleaseWaiters.append($0) }
        }
        closeFinished = true
    }

    func waitUntilCloseStarted() async {
        guard !closeStarted else { return }
        await withCheckedContinuation { closeStartWaiters.append($0) }
    }

    func releaseClose() {
        closeReleased = true
        let releaseWaiters = closeReleaseWaiters
        closeReleaseWaiters.removeAll()
        for waiter in releaseWaiters { waiter.resume() }
    }

    func didFinishClose() -> Bool { closeFinished }
}
