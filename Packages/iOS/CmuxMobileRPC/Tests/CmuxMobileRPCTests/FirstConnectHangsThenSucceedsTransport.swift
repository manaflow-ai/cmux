import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor FirstConnectHangsThenSucceedsTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var queuedResponses: [Data] = []
    private var firstConnectWaiter: CheckedContinuation<Void, Never>?
    private var firstAttemptClosed = false
    private var connects = 0
    private var isClosed = false

    func connect() async throws {
        connects += 1
        if connects == 1 {
            await withCheckedContinuation { continuation in
                if firstAttemptClosed {
                    continuation.resume()
                } else {
                    firstConnectWaiter = continuation
                }
            }
            throw CancellationError()
        }
        isClosed = false
    }

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
        sentPayloads.append(contentsOf: payloads)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            try enqueueResponse(id: request.id)
        }
    }

    func close() async {
        isClosed = true
        if connects == 1 {
            firstAttemptClosed = true
            firstConnectWaiter?.resume()
            firstConnectWaiter = nil
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func connectCount() -> Int {
        connects
    }

    func waitUntilFirstAttemptClosed() async -> Bool {
        for _ in 0..<200 {
            if firstAttemptClosed {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return firstAttemptClosed
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
