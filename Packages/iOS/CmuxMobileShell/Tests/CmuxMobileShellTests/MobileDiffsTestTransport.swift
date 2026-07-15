import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor MobileDiffsTestTransport: CmxByteTransport {
    private let host: MobileDiffsTestHost
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(host: MobileDiffsTestHost) {
        self.host = host
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
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            let params = object?["params"] as? [String: Any]
            let baseSpec = params?["baseSpec"] as? [String: Any]
            let request = MobileDiffsTestRequest(
                method: object?["method"] as? String,
                id: object?["id"] as? String,
                workspaceRef: params?["workspaceRef"] as? String,
                baseKind: baseSpec?["kind"] as? String,
                baseValue: baseSpec?["value"] as? String,
                ignoreWhitespace: params?["ignoreWhitespace"] as? Bool,
                path: params?["path"] as? String,
                oldPath: params?["oldPath"] as? String,
                cursor: (params?["cursor"] as? NSNumber)?.intValue,
                force: params?["force"] as? Bool,
                startLine: (params?["startLine"] as? NSNumber)?.intValue,
                endLine: (params?["endLine"] as? NSNumber)?.intValue
            )
            if let response = await host.response(to: request) {
                deliver(response)
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
        guard !receiveWaiters.isEmpty else {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }
}
