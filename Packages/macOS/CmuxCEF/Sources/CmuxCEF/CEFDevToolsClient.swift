public import Foundation

/// Correlates DevTools protocol commands with their results for one browser.
///
/// The transport is CEF's in-process `SendDevToolsMessage` seam, so there is
/// no socket and no serialization beyond JSON. Events (messages without an
/// `id`) are forwarded to `events` subscribers.
@MainActor
public final class CEFDevToolsClient {
    /// A JSON-decoded DevTools event.
    public struct Event: Sendable {
        /// Protocol method name, e.g. `Page.loadEventFired`.
        public let method: String
        /// Raw UTF-8 JSON of the full event envelope.
        public let payload: Data
    }

    /// Failure surface for command submission and completion.
    public enum ClientError: Error, Sendable {
        /// The browser is closed or the message could not be submitted.
        case notConnected
        /// The protocol reported an error for this command.
        case commandFailed(String)
        /// The protocol did not answer before the bounded command deadline.
        case timedOut
    }

    private let browser: CEFBrowser
    private var nextCommandID = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?

    /// Creates a client bound to one browser and starts receiving.
    ///
    /// - Parameter browser: The CEF browser whose DevTools seam to use.
    public init(browser: CEFBrowser) {
        self.browser = browser
        let messages = browser.devToolsMessages()
        receiveTask = Task { [weak self] in
            for await message in messages {
                self?.receive(message)
            }
            self?.connectionEnded()
        }
    }

    deinit {
        receiveTask?.cancel()
    }

    /// Sends one protocol command and awaits its result payload.
    ///
    /// - Parameters:
    ///   - method: Protocol function, e.g. `Runtime.evaluate`.
    ///   - params: JSON-compatible parameter dictionary.
    ///   - timeout: Maximum time to await a protocol response.
    /// - Returns: The raw UTF-8 JSON of the `result` object.
    /// - Throws: ``ClientError`` on submission, timeout, or protocol failure.
    public func send(
        method: String,
        params: [String: Any] = [:],
        timeout: Duration = .seconds(15)
    ) async throws -> Data {
        let id = nextCommandID
        nextCommandID += 1
        var envelope: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { envelope["params"] = params }
        let message = try JSONSerialization.data(withJSONObject: envelope)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw ClientError.notConnected }
                return try await self.sendPendingCommand(id: id, message: message)
            }
            group.addTask {
                // A stalled renderer is a genuine operation deadline; the
                // losing command task is cancelled and removes its waiter.
                try await ContinuousClock().sleep(for: timeout)
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func sendPendingCommand(id: Int, message: Data) async throws -> Data {
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending[id] = continuation
                    guard browser.sendDevToolsMessage(message) else {
                        pending.removeValue(forKey: id)?.resume(
                            throwing: ClientError.notConnected
                        )
                        return
                    }
                }
            },
            onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelPendingCommand(id: id)
                }
            }
        )
    }

    /// Streams protocol events until the browser closes.
    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func receive(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message)
                as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? "DevTools command failed"
                continuation.resume(throwing: ClientError.commandFailed(text))
                return
            }
            let result = (try? JSONSerialization.data(
                withJSONObject: object["result"] ?? [:]
            )) ?? Data("{}".utf8)
            continuation.resume(returning: result)
            return
        }
        guard let method = object["method"] as? String else { return }
        let event = Event(method: method, payload: message)
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func connectionEnded() {
        let waiters = pending
        pending.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: ClientError.notConnected)
        }
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    private func cancelPendingCommand(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
