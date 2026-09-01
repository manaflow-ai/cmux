import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

/// A deterministic byte transport that emits one fixed path and mock RPC responses.
actor FinitePathObservationTransport: CmxByteTransportPathObserving {
    private let path: CmxTransportPath
    private var queuedFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var pathContinuation: AsyncStream<CmxTransportPath>.Continuation?
    private var isClosed = false

    init(path: CmxTransportPath) {
        self.path = path
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            guard let request = try JSONSerialization.jsonObject(with: payload)
                    as? [String: Any],
                  let id = request["id"] as? String else {
                continue
            }
            let response: [String: Any] = [
                "id": id,
                "ok": true,
                "result": [:],
            ]
            let responseData = try JSONSerialization.data(withJSONObject: response)
            let frame = try MobileSyncFrameCodec.encodeFrame(responseData)
            if let waiter = receiveWaiters.first {
                receiveWaiters.removeFirst()
                waiter.resume(returning: frame)
            } else {
                queuedFrames.append(frame)
            }
        }
    }

    func close() async {
        isClosed = true
        pathContinuation?.finish()
        pathContinuation = nil
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func currentTransportPath() async -> CmxTransportPath { path }

    func transportPathChanges() async -> AsyncStream<CmxTransportPath> {
        let (stream, continuation) = AsyncStream<CmxTransportPath>.makeStream()
        pathContinuation = continuation
        continuation.yield(path)
        return stream
    }

    func finishPathObservation() {
        pathContinuation?.finish()
        pathContinuation = nil
    }
}
