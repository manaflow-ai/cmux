import CMUXMobileCore
import Foundation
import Testing

actor AttachTokenFallbackTransport: CmxByteTransport {
    private let firstErrorCode: String
    private let firstErrorMessage: String
    private var sentPayloads: [Data] = []
    private var inboundFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(
        firstErrorCode: String = "unauthorized",
        firstErrorMessage: String = "Mobile sync authorization failed."
    ) {
        self.firstErrorCode = firstErrorCode
        self.firstErrorMessage = firstErrorMessage
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !inboundFrames.isEmpty {
            return inboundFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            sentPayloads.append(payload)
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let id = try #require(request["id"] as? String)
            let response: [String: Any]
            if sentPayloads.count == 1 {
                response = [
                    "id": id,
                    "ok": false,
                    "error": [
                        "code": firstErrorCode,
                        "message": firstErrorMessage,
                    ],
                ]
            } else {
                response = [
                    "id": id,
                    "ok": true,
                    "result": ["accepted": true],
                ]
            }
            inboundFrames.append(try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: response)))
        }
        resumeReceiveWaiters()
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }

    private func resumeReceiveWaiters() {
        while !inboundFrames.isEmpty && !receiveWaiters.isEmpty {
            receiveWaiters.removeFirst().resume(returning: inboundFrames.removeFirst())
        }
    }
}
