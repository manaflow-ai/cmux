import CMUXMobileCore
import Foundation

struct RoutingTransportFactory: CmxByteTransportFactory {
    let router: RoutingHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        RoutingTransport(router: router)
    }
}

private actor RoutingTransport: CmxByteTransport {
    private let router: RoutingHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: RoutingHostRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed { return nil }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let params = parsed?["params"] as? [String: Any]
            let info = RoutingHostRouter.RequestInfo(
                method: parsed?["method"] as? String,
                id: parsed?["id"] as? String,
                surfaceID: params?["surface_id"] as? String,
                imageFormat: params?["image_format"] as? String,
                text: params?["text"] as? String,
                notificationIDs: params?["notification_ids"] as? [String],
                clientID: params?["client_id"] as? String,
                groupID: params?["group_id"] as? String,
                workspaceID: params?["workspace_id"] as? String
            )
            Task { [router, weak self] in
                guard let response = await router.response(info) else { return }
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
