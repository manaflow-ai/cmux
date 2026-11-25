import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor ReleasableConnectTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var queuedResponses: [Data] = []
    private var connectStarted = false
    private var connectReleased = false
    private var isClosed = false
    private var closeStarted = false
    private var closeReleased: Bool
    private var closeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdsClose: Bool = false) {
        closeReleased = !holdsClose
    }

    func connect() async throws {
        connectStarted = true
        if isClosed {
            throw CancellationError()
        }
        if connectReleased {
            return
        }
        await withCheckedContinuation { continuation in
            if connectReleased || isClosed {
                continuation.resume()
            } else {
                connectWaiter = continuation
            }
        }
        if isClosed {
            throw CancellationError()
        }
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
        connectWaiter?.resume()
        connectWaiter = nil
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        closeStarted = true
        for waiter in closeStartWaiters {
            waiter.resume()
        }
        closeStartWaiters = []
        guard !closeReleased else { return }
        await withCheckedContinuation {
            closeReleaseWaiters.append($0)
        }
    }

    func releaseConnect() {
        connectReleased = true
        connectWaiter?.resume()
        connectWaiter = nil
    }

    func closed() -> Bool {
        isClosed
    }

    func waitUntilCloseStarted() async {
        if closeStarted { return }
        await withCheckedContinuation {
            closeStartWaiters.append($0)
        }
    }

    func releaseClose() {
        closeReleased = true
        for waiter in closeReleaseWaiters {
            waiter.resume()
        }
        closeReleaseWaiters = []
    }

    func waitUntilConnectStarted() async -> Bool {
        for _ in 0..<200 {
            if connectStarted {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return connectStarted
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
