import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor ControllableResponseTransport: CmxByteTransport {
    private let closeEndsReceive: Bool
    private let blocksFirstSend: Bool
    private let automaticallyRespondingRequestIDs: Set<String>
    private var queuedFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var sentRequestIDs: [String] = []
    private var sendCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var firstSendReleased = false
    private var isClosed = false

    init(
        closeEndsReceive: Bool,
        blocksFirstSend: Bool = false,
        automaticallyRespondingRequestIDs: Set<String> = []
    ) {
        self.closeEndsReceive = closeEndsReceive
        self.blocksFirstSend = blocksFirstSend
        self.automaticallyRespondingRequestIDs = automaticallyRespondingRequestIDs
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedFrames.isEmpty { return queuedFrames.removeFirst() }
        if isClosed, closeEndsReceive { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        var requests: [RecordedRPCRequest] = []
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            let request = try recordedRPCRequest(from: payload)
            requests.append(request)
            sentRequestIDs.append(request.id ?? "")
        }
        let ready = sendCountWaiters.filter { sentRequestIDs.count >= $0.0 }
        sendCountWaiters.removeAll { sentRequestIDs.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        if blocksFirstSend, sentRequestIDs.count == 1, !firstSendReleased {
            await withCheckedContinuation { firstSendContinuation = $0 }
        }
        for request in requests {
            guard let id = request.id, automaticallyRespondingRequestIDs.contains(id) else {
                continue
            }
            try deliverResponse(id: id, status: "ok")
        }
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

    func sentIDs() -> [String] {
        sentRequestIDs
    }

    func releaseFirstSend() {
        firstSendReleased = true
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }

    func closed() -> Bool {
        isClosed
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
