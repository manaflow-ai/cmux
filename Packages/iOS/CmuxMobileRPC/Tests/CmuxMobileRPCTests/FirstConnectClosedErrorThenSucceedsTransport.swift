import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

/// First connect waits for `close()`, then surfaces a transport-specific close
/// error instead of `CancellationError`. A second connect succeeds.
actor FirstConnectClosedErrorThenSucceedsTransport: CmxByteTransport {
    private struct SyntheticClosedError: Error {}

    private var sentPayloads: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var queuedResponses: [Data] = []
    private var firstConnectRelease: CheckedContinuation<Void, Never>?
    private var firstConnectStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstConnectFinishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstConnectStarted = false
    private var firstConnectFinished = false
    private var connects = 0
    private var isClosed = false

    func connect() async throws {
        connects += 1
        if connects == 1 {
            firstConnectStarted = true
            let startedWaiters = firstConnectStartedWaiters
            firstConnectStartedWaiters = []
            for waiter in startedWaiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstConnectRelease = continuation
            }
            firstConnectFinished = true
            let finishedWaiters = firstConnectFinishedWaiters
            firstConnectFinishedWaiters = []
            for waiter in finishedWaiters {
                waiter.resume()
            }
            throw SyntheticClosedError()
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
            firstConnectRelease?.resume()
            firstConnectRelease = nil
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func waitUntilFirstConnectStarted() async {
        if firstConnectStarted {
            return
        }
        await withCheckedContinuation { continuation in
            firstConnectStartedWaiters.append(continuation)
        }
    }

    func waitUntilFirstConnectFinished() async {
        if firstConnectFinished {
            return
        }
        await withCheckedContinuation { continuation in
            firstConnectFinishedWaiters.append(continuation)
        }
    }

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
