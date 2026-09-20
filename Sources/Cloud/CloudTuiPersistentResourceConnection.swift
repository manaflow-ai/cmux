import CoreFoundation
import Foundation

enum CloudTuiSendError: Error {
    case notSent(Error)
    case ambiguous(Error)
}

/// One machine-owned control connection. Only this actor owns request IDs,
/// continuations, deadlines and event subscriptions. Never retries a mutation:
/// a caller retains its idempotency key when an outcome is uncertain.
actor CloudTuiPersistentResourceConnection {
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let request: CloudTuiRequest
        let deadline: Task<Void, Never>
        let isExpired: @Sendable () -> Bool
        var sendTask: Task<Void, Never>?
    }
    private struct Subscription {
        let continuation: AsyncStream<Data>.Continuation
        var sequence: UInt64 = 0
    }
    private let connection: CloudTuiManualIOConnection
    private let clock: any Clock<Duration>
    private let namespace = UUID().uuidString.lowercased()
    private var sequence: UInt64 = 0
    private var pending: [String: Pending] = [:]
    private var subscriptions: [String: Subscription] = [:]
    private var sendTail: Task<Void, Never>?
    private var sendTailToken: UUID?
    private var startTask: Task<Void, Error>?
    private var pumpTask: Task<Void, Never>?
    private var closed = false
    private let pendingLimit = 128
    private static let protocolFailure = CloudMachineLink.LinkError.exited(status: 3, output: "transport closed: invalid resource response")

    init(socketPath: String, clock: any Clock<Duration> = ContinuousClock()) {
        connection = CloudTuiManualIOConnection(socketPath: socketPath, deliversJSONMessages: true)
        self.clock = clock
    }

    deinit { pumpTask?.cancel(); startTask?.cancel(); connection.close() }

    func start() async throws {
        guard !closed else { throw Self.protocolFailure }
        if let startTask { return try await startTask.value }
        let connection = connection
        let task = Task { try await connection.start() }
        startTask = task
        do { try await task.value } catch { close(); throw error }
        guard !closed else { throw Self.protocolFailure }
        pumpTask = Task { [weak self, connection] in
            for await frame in connection.events {
                guard case let .message(data) = frame else { continue }
                await self?.receive(data)
            }
            await self?.close()
        }
    }

    var isClosed: Bool { closed }

    func close() {
        guard !closed else { return }
        closed = true
        startTask?.cancel()
        pumpTask?.cancel()
        pumpTask = nil
        connection.close()
        let requests = pending
        pending.removeAll()
        for entry in requests.values {
            entry.deadline.cancel()
            entry.continuation.resume(throwing: Self.protocolFailure)
        }
        for stream in subscriptions.values { stream.continuation.finish() }
        subscriptions.removeAll()
    }

    private func nextID() -> String {
        sequence += 1
        return "request-\(namespace)-\(sequence)"
    }

    func request(_ request: CloudTuiRequest, timeout: Duration = .seconds(30)) async throws -> Data {
        // Explicit `self.` is required: the compiler declines to open the
        // existential when the argument is an implicit-self stored property.
        try await performRequest(request, timeout: timeout, clock: self.clock)
    }

    private func performRequest<RequestClock: Clock>(
        _ request: CloudTuiRequest, timeout: Duration, clock: RequestClock
    ) async throws -> Data where RequestClock.Duration == Duration {
        try Task.checkCancellation()
        guard timeout > .zero else { throw CloudMachineLink.LinkError.timedOut }
        try await start()
        try Task.checkCancellation()
        guard !closed else { throw Self.protocolFailure }
        guard pending.count < pendingLimit else {
            throw CloudMachineLink.LinkError.exited(status: 3, output: "transport busy: request not sent")
        }
        let id = nextID()
        let encoded = try request.envelope(id: id)
        guard encoded.count <= 256 * 1024 - 1 else { throw CloudMachineLink.LinkError.inputTooLarge }
        let expiresAt = clock.now.advanced(by: timeout)
        let result: Data = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // A genuine request deadline, owned and cancelled with its pending entry.
                let deadline = Task { [weak self, clock] in
                    do { try await clock.sleep(until: expiresAt, tolerance: nil) } catch { return }
                    await self?.retire(id, error: CloudMachineLink.LinkError.timedOut)
                }
                pending[id] = Pending(
                    continuation: continuation, request: request, deadline: deadline,
                    isExpired: { clock.now >= expiresAt }, sendTask: nil
                )
                let token = UUID()
                let previous = sendTail
                let orderedSendTask: Task<Void, Never> = Task { [weak self, previous] in
                    await previous?.value
                    guard !Task.isCancelled, let self else { return }
                    await self.sendIfPending(id, connection: connection, line: encoded + Data([0x0A]))
                    await self.finishSendTail(token)
                }
                sendTail = orderedSendTask
                sendTailToken = token
                pending[id]?.sendTask = orderedSendTask
            }
        }, onCancel: { [weak self] in
            Task { await self?.retire(id, error: CancellationError()) }
        })
        // The cancellation handler's actor hop can arrive after a successful response.
        try Task.checkCancellation()
        return result
    }

    private func retire(_ id: String, error: Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.deadline.cancel()
        entry.sendTask?.cancel()
        entry.continuation.resume(throwing: error)
        // Cancellation is request-local, never close siblings' shared socket.
        // A mutation that already committed remains fenced by its original key.
        if !entry.request.raw { sendBestEffort(CloudTuiRequest("request.cancel", ["request_id": id])) }
    }

    private func sendFailed(_ id: String, error: Error) {
        let mapped: Error
        if let sendError = error as? CloudTuiManualIOConnection.CheckedSendError {
            switch sendError {
            case .notSent, .bufferFull:
                mapped = CloudTuiSendError.notSent(error)
            case .ambiguous:
                mapped = CloudTuiSendError.ambiguous(error)
            }
        } else {
            mapped = CloudTuiSendError.ambiguous(error)
        }
        retire(id, error: mapped)
    }

    private func sendIfPending(
        _ id: String,
        connection: CloudTuiManualIOConnection,
        line: Data
    ) async {
        guard pending[id] != nil else { return }
        do {
            try await connection.sendChecked(line: line)
        } catch {
            guard pending[id] != nil else { return }
            sendFailed(id, error: error)
        }
    }

    private func finishSendTail(_ token: UUID) {
        guard sendTailToken == token else { return }
        sendTail = nil
        sendTailToken = nil
    }

    private func sendBestEffort(_ request: CloudTuiRequest) {
        guard !closed, let data = try? request.envelope(id: nextID()) else { return }
        connection.send(line: data + Data([0x0A]))
    }

    /// Writes a request on this authenticated channel without waiting for its
    /// response. The daemon still emits a normal response, which the reader
    /// safely ignores after the request has been handed to the socket.
    func sendUntracked(_ request: CloudTuiRequest) async throws {
        try Task.checkCancellation()
        try await start()
        try Task.checkCancellation()
        guard !closed else { throw Self.protocolFailure }
        let encoded = try request.envelope(id: nextID())
        guard encoded.count <= 256 * 1024 - 1 else { throw CloudMachineLink.LinkError.inputTooLarge }
        do {
            try await connection.sendChecked(line: encoded + Data([0x0A]))
        } catch let error as CloudTuiManualIOConnection.CheckedSendError {
            switch error {
            case .notSent, .bufferFull:
                throw CloudTuiSendError.notSent(error)
            case .ambiguous:
                throw CloudTuiSendError.ambiguous(error)
            }
        }
    }

    /// Open the revisioned event feed on the control connection. One queued
    /// envelope bounds memory; overflow explicitly requests snapshot recovery.
    func events(cursor: CloudVMCursor?) async throws -> (id: String, stream: AsyncStream<Data>) {
        try await start()
        let id = "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscriptions[id] = Subscription(continuation: pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.cancelStream(id) } }
        var fields: [String: Any] = ["stream_id": id]
        if let cursor { fields["cursor"] = ["generation": cursor.generation, "revision": String(cursor.revision)] }
        do {
            let result = try await request(CloudTuiRequest("session.events", fields))
            guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any], object["stream_id"] as? String == id else {
                throw Self.protocolFailure
            }
            return (id, pair.stream)
        } catch { cancelStream(id); throw error }
    }

    func cancelStream(_ id: String) {
        guard let stream = subscriptions.removeValue(forKey: id) else { return }
        stream.continuation.finish()
        sendBestEffort(CloudTuiRequest("stream.cancel", ["stream": id]))
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { close(); return }
        if let type = root["type"] as? String, type == "stream_item" || type == "stream_end" {
            guard root["protocol"] as? String == "cmux.protocol/2", let id = root["stream_id"] as? String else { close(); return }
            guard var subscription = subscriptions[id] else { return }
            if type == "stream_item" {
                guard let raw = root["sequence"] as? String, let next = UInt64(raw), next == subscription.sequence else {
                    cancelStream(id); return
                }
                subscription.sequence = next + 1
                subscriptions[id] = subscription
            }
            if case .dropped = subscription.continuation.yield(data) { cancelStream(id); return }
            if type == "stream_end" { cancelStream(id) }
            return
        }
        guard let id = root["id"] as? String,
              let ok = root["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else { close(); return }
        guard let entry = pending[id] else {
            // Responses to cancellation and retired requests are harmless.
            guard id.hasPrefix("request-\(namespace)-"), let suffix = id.split(separator: "-").last,
                  let issued = UInt64(suffix), issued > 0, issued <= sequence else { close(); return }
            return
        }
        // After suspend/resume, the socket reader may run before the deadline task.
        guard !entry.isExpired() else {
            retire(id, error: CloudMachineLink.LinkError.timedOut)
            return
        }
        pending.removeValue(forKey: id)
        entry.deadline.cancel()
        if !entry.request.raw && (root["protocol"] as? String != "cmux.protocol/2" || root["type"] as? String != "response") {
            entry.continuation.resume(throwing: Self.protocolFailure); close(); return
        }
        if !ok.boolValue {
            let errorObject: Any = entry.request.raw
                ? ["code": "raw.command_failed", "details": ["error": root["error"] ?? "request rejected"]]
                : root["error"] ?? [:]
            let errorData = (try? JSONSerialization.data(withJSONObject: errorObject)) ?? Data()
            entry.continuation.resume(throwing: CloudMachineLink.LinkError.exited(status: 1, output: String(decoding: errorData, as: UTF8.self)))
        } else if entry.request.raw {
            if let value = root["data"], let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                entry.continuation.resume(returning: encoded)
            } else { entry.continuation.resume(throwing: Self.protocolFailure); close() }
        } else if let result = root["result"], !(result is NSNull), let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            entry.continuation.resume(returning: bytes)
        } else {
            entry.continuation.resume(throwing: Self.protocolFailure); close()
        }
    }
}
