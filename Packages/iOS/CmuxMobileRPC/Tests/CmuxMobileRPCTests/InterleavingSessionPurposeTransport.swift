import CMUXMobileCore
import Foundation

actor InterleavingSessionPurposeTransport:
    CmxByteTransport,
    CmxByteTransportSessionPurposeUpdating
{
    private let base = ControllableResponseTransport(
        closeEndsReceive: true,
        automaticallyRespondingRequestIDs: ["purpose-probe"]
    )
    private var purpose: CmxTransportSessionPurpose?
    private var completedPurposes: [CmxTransportSessionPurpose] = []
    private var purposeToBlock: CmxTransportSessionPurpose?
    private var blockedPurpose: CmxTransportSessionPurpose?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedRelease: CheckedContinuation<Void, Never>?

    func blockNextUpdate(to purpose: CmxTransportSessionPurpose) {
        purposeToBlock = purpose
    }

    func updateSessionPurpose(
        _ nextPurpose: CmxTransportSessionPurpose
    ) async {
        if purposeToBlock == nextPurpose {
            purposeToBlock = nil
            blockedPurpose = nextPurpose
            for waiter in blockedWaiters { waiter.resume() }
            blockedWaiters = []
            await withCheckedContinuation {
                blockedRelease = $0
            }
        }
        purpose = nextPurpose
        completedPurposes.append(nextPurpose)
    }

    func waitUntilUpdateIsBlocked(
        on expectedPurpose: CmxTransportSessionPurpose
    ) async {
        if blockedPurpose == expectedPurpose { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func releaseBlockedUpdate() {
        blockedPurpose = nil
        blockedRelease?.resume()
        blockedRelease = nil
    }

    func currentPurpose() -> CmxTransportSessionPurpose? { purpose }
    func recordedCompletedPurposes() -> [CmxTransportSessionPurpose] {
        completedPurposes
    }
    func connect() async throws { try await base.connect() }
    func receive() async throws -> Data? { try await base.receive() }
    func send(_ data: Data) async throws { try await base.send(data) }
    func close() async { await base.close() }
}
