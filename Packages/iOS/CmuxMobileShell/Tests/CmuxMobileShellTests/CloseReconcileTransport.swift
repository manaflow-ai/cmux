import CMUXMobileCore
import Foundation

actor CloseReconcileTransport: CmxByteTransport {
    private let router: CloseReconcileHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: CloseReconcileHostRouter) {
        self.router = router
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
            let method = parsed?["method"] as? String
            let id = parsed?["id"] as? String
            Task { [router, weak self] in
                guard let response = await router.response(method: method, id: id) else { return }
                await self?.deliver(response)
            }
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
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}
