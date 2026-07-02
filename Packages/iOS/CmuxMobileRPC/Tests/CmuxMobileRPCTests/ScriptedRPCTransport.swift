import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor ScriptedRPCTransport: CmxByteTransport {
    typealias Handler = @Sendable (_ payload: Data) async throws -> [String: Any]

    private let handler: Handler
    private var sentPayloads: [Data] = []
    private var queuedResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if isClosed {
            return nil
        }
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
        for payload in payloads {
            sentPayloads.append(payload)
            try enqueueResponse(try await handler(payload))
        }
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

    func waitForSentRequestCount(_ count: Int) async throws -> [RecordedRPCRequest] {
        var requests: [RecordedRPCRequest] = []
        for _ in 0..<200 {
            requests = try sentRequests()
            if requests.count >= count {
                return requests
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return requests
    }

    private func enqueueResponse(_ envelope: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let frame = try MobileSyncFrameCodec.encodeFrame(data)
        if receiveWaiters.isEmpty {
            queuedResponses.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}
