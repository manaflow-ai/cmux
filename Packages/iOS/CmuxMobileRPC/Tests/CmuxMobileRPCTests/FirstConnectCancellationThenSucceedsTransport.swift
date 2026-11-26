import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor FirstConnectCancellationThenSucceedsTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var queuedResponses: [Data] = []
    private var connects = 0

    func connect() async throws {
        connects += 1
        if connects == 1 {
            throw CancellationError()
        }
    }

    func receive() async throws -> Data? {
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            try enqueueResponse(id: request.id)
        }
    }

    func close() async {}

    func connectCount() -> Int {
        connects
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }

    private func enqueueResponse(id: String?) throws {
        let response: [String: Any] = [
            "id": id ?? "",
            "ok": true,
            "result": ["status": "ok"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: response)
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: frame)
        } else {
            queuedResponses.append(frame)
        }
    }
}
