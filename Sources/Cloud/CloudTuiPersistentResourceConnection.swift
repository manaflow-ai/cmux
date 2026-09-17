import Foundation

/// One request/response multiplexer over the link's already-authenticated
/// cmux-tui Unix socket. The socket reader is shared by every resource command;
/// request IDs keep concurrent snapshots and mutations independent.
final class CloudTuiPersistentResourceConnection: @unchecked Sendable {
    private let connection: CloudTuiManualIOConnection
    private let queue = DispatchQueue(label: "com.cmux.cloud-resource-multiplexer", qos: .userInitiated)
    private var nextRequestID: UInt64 = 1
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var pumpTask: Task<Void, Never>?

    init(socketPath: String) {
        connection = CloudTuiManualIOConnection(socketPath: socketPath)
    }

    func start() async throws {
        try await connection.start()
        pumpTask = Task { [weak self, connection] in
            for await frame in connection.events {
                guard let self else { return }
                self.handle(frame)
            }
            self.failAll(CloudTuiPersistentResourceError.disconnected)
        }
    }

    func close() {
        pumpTask?.cancel()
        pumpTask = nil
        connection.close()
        failAll(CloudTuiPersistentResourceError.disconnected)
    }

    func request(operation: String, params: [String: Any], idempotencyKey: String? = nil, timeout: Duration = .seconds(30)) async throws -> Data {
        let requestID = queue.sync {
            defer { nextRequestID &+= 1 }
            return "cloud-request-\(nextRequestID)"
        }
        var envelope: [String: Any] = [
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": requestID,
            "operation": operation,
            "params": params,
        ]
        if let idempotencyKey { envelope["idempotency_key"] = idempotencyKey }
        guard let line = try? JSONSerialization.data(withJSONObject: envelope).appending(Data([0x0A])) else {
            throw CloudTuiPersistentResourceError.encoding
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CloudTuiPersistentResourceError.disconnected }
                return try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        self.pending[requestID] = continuation
                        self.connection.send(line: line)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CloudTuiPersistentResourceError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func handle(_ frame: CloudTuiManualIOFrame) {
        guard case let .resourceResponse(requestID, ok, result, error) = frame else { return }
        queue.async {
            guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
            if ok, let result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CloudTuiPersistentResourceError.remote(error))
            }
        }
    }

    private func failAll(_ error: Error) {
        queue.async {
            let continuations = self.pending.values
            self.pending.removeAll()
            for continuation in continuations { continuation.resume(throwing: error) }
        }
    }
}

enum CloudTuiPersistentResourceError: Error, LocalizedError {
    case disconnected
    case encoding
    case timeout
    case remote(Data?)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "The persistent Cloud cmux-tui connection closed."
        case .encoding: return "The Cloud resource request could not be encoded."
        case .timeout: return "The Cloud resource request timed out."
        case .remote(let data): return data.flatMap { String(data: $0, encoding: .utf8) } ?? "The Cloud resource request failed."
        }
    }
}
