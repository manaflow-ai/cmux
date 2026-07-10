import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor ImmediateResponseRecordingTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var queuedResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedResponses.isEmpty {
            return queuedResponses.removeFirst()
        }
        if isClosed { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            try deliverResponse(id: request.id)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }

    private func deliverResponse(id: String?) throws {
        let response: [String: Any] = [
            "id": id ?? "",
            "ok": true,
            "result": ["status": "ok"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: response)
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        if !receiveWaiters.isEmpty {
            receiveWaiters.removeFirst().resume(returning: frame)
        } else {
            queuedResponses.append(frame)
        }
    }
}
