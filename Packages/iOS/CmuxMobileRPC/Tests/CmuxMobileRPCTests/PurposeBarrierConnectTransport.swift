import CMUXMobileCore
import Foundation

actor PurposeBarrierConnectTransport:
    CmxByteTransport,
    CmxByteTransportSessionPurposeUpdating
{
    private let base = ReleasableConnectTransport()
    private var purposeUpdateCount = 0
    private var postConnectPurposeWaiters:
        [CheckedContinuation<Void, Never>] = []

    func updateSessionPurpose(_: CmxTransportSessionPurpose) async {
        purposeUpdateCount += 1
        guard purposeUpdateCount > 1 else { return }
        if purposeUpdateCount >= 3 {
            let waiters = postConnectPurposeWaiters
            postConnectPurposeWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            postConnectPurposeWaiters.append(continuation)
        }
    }

    func connect() async throws { try await base.connect() }
    func receive() async throws -> Data? { try await base.receive() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func close() async {
        await base.close()
        let waiters = postConnectPurposeWaiters
        postConnectPurposeWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func releaseConnect() async { await base.releaseConnect() }
    func waitUntilConnectStarted() async -> Bool {
        await base.waitUntilConnectStarted()
    }
    func closed() async -> Bool { await base.closed() }
    func sentRequests() async throws -> [RecordedRPCRequest] {
        try await base.sentRequests()
    }
}
