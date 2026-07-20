import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor ControllableResponseTransport: CmxByteTransport {
    private let closeEndsReceive: Bool
    private var queuedFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var sentRequestIDs: [String] = []
    private var sendCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isClosed = false

    init(closeEndsReceive: Bool) {
        self.closeEndsReceive = closeEndsReceive
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedFrames.isEmpty { return queuedFrames.removeFirst() }
        if isClosed, closeEndsReceive { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            let request = try recordedRPCRequest(from: payload)
            sentRequestIDs.append(request.id ?? "")
        }
        let ready = sendCountWaiters.filter { sentRequestIDs.count >= $0.0 }
        sendCountWaiters.removeAll { sentRequestIDs.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    func close() async {
        isClosed = true
        guard closeEndsReceive else { return }
        finishReceiving()
    }

    func waitUntilSent(count: Int) async {
        if sentRequestIDs.count >= count { return }
        await withCheckedContinuation { sendCountWaiters.append((count, $0)) }
    }

    func deliverResponse(id: String, status: String) throws {
        let response: [String: Any] = [
            "id": id,
            "ok": true,
            "result": ["status": status],
        ]
        let payload = try JSONSerialization.data(withJSONObject: response)
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: frame)
        } else {
            queuedFrames.append(frame)
        }
    }

    func finishReceiving() {
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters { waiter.resume(returning: nil) }
    }
}
