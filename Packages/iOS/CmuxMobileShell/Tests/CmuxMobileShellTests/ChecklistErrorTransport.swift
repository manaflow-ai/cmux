import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Answers every framed request with one configured RPC error frame.
actor ChecklistErrorTransport: CmxByteTransport {
    private let code: String?
    private let message: String
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(code: String?, message: String) {
        self.code = code
        self.message = message
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
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
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            guard let id = parsed?["id"] as? String else { continue }
            var error: [String: Any] = ["message": message]
            if let code {
                error["code"] = code
            }
            let envelope: [String: Any] = ["id": id, "ok": false, "error": error]
            guard let frame = try? MobileSyncFrameCodec.encodeFrame(
                JSONSerialization.data(withJSONObject: envelope)
            ) else { continue }
            deliver(frame)
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

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }
}
