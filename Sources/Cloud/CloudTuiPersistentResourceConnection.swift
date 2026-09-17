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
        enum Outcome: Sendable {
            case response(Result<Data, Error>)
            case timeout
        }
        return try await withTaskCancellationHandler(operation: {
            let outcome = await withTaskGroup(of: Outcome.self) { group -> Outcome in
                group.addTask { [weak self] in
                    guard let self else { return .response(.failure(CloudTuiPersistentResourceError.disconnected)) }
                    do {
                        let data = try await withCheckedThrowingContinuation { continuation in
                            self.queue.async {
                                self.pending[requestID] = continuation
                                self.connection.send(line: line)
                            }
                        }
                        return .response(.success(data))
                    } catch {
                        return .response(.failure(error))
                    }
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .timeout
                    } catch {
                        return .response(.failure(CancellationError()))
                    }
                }
                let first = await group.next() ?? .response(.failure(CloudTuiPersistentResourceError.disconnected))
                group.cancelAll()
                return first
            }
            if case .timeout = outcome {
                removePending(requestID, error: CloudTuiPersistentResourceError.timeout)
                throw CloudTuiPersistentResourceError.timeout
            }
            guard case let .response(result) = outcome else {
                throw CloudTuiPersistentResourceError.disconnected
            }
            return try result.get()
        }, onCancel: { [weak self] in
            self?.removePending(requestID, error: CancellationError())
        })
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

    private func removePending(_ requestID: String, error: Error) {
        queue.async {
            guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
            continuation.resume(throwing: error)
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
