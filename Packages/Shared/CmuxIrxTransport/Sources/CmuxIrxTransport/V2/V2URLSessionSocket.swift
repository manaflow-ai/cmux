public import Foundation
import os

/// Adapts a URLSession WebSocket to the shared actor's transport seam.
public actor V2URLSessionSocket: V2ControlSocket {
    private let task: URLSessionWebSocketTask

    /// Starts a socket using the caller's URLSession and complete v2 handshake.
    /// - Parameters:
    ///   - session: A session owned by the composition root.
    ///   - request: The authenticated `/v2/control/socket` upgrade request.
    public init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1024 * 1024
        task.resume()
    }

    /// Sends one JSON text frame.
    /// - Parameter data: Valid UTF-8 JSON.
    /// - Throws: A transport or encoding error.
    public func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw V2ControlFailure.invalidWireData }
        do { try await task.send(.string(text)) }
        catch { throw mapped(error) }
    }

    /// Receives a text or binary frame without a custom idle timer.
    /// - Returns: The complete message.
    /// - Throws: A transport or upgrade-status error.
    public func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            case .string(let string): return Data(string.utf8)
            @unknown default: throw V2ControlFailure.invalidWireData
            }
        } catch { throw mapped(error) }
    }

    /// Runs a native protocol ping without sending an application heartbeat.
    /// - Throws: A transport error when the ping fails.
    public func ping() async throws {
        do {
            try await Self.ping(using: task.sendPing)
        } catch { throw mapped(error) }
    }

    // Keep the native callback bridge independently exercisable, including
    // duplicate callbacks delivered by URLSession during network teardown.
    static func ping(
        using sendPing: (@escaping @Sendable ((any Error)?) -> Void) -> Void
    ) async throws {
        let completion = V2URLSessionPingCompletion()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard completion.install(continuation) else { return }
                guard !Task.isCancelled else {
                    completion.cancel()
                    return
                }
                sendPing { error in completion.callback(error) }
            }
        }, onCancel: {
            completion.cancel()
        })
    }

    /// Serializes the synchronous callback/cancellation race at the URLSession seam.
    private final class V2URLSessionPingCompletion: @unchecked Sendable {
        deinit {}

        private struct State: Sendable {
            var continuation: CheckedContinuation<Void, any Error>?
            var result: Result<Void, any Error>?
        }

        // lint:allow lock -- URLSession callbacks and task cancellation can race synchronously;
        // an actor would add an async hop between claiming and resuming a continuation.
        private let state = OSAllocatedUnfairLock(initialState: State())

        func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
            enum Action {
                case installed
                case completed(Result<Void, any Error>)
            }

            let action = state.withLock { state -> Action in
                guard let result = state.result else {
                    state.continuation = continuation
                    return .installed
                }
                return .completed(result)
            }

            switch action {
            case .installed:
                return true
            case .completed(let result):
                continuation.resume(with: result)
            }
            return false
        }

        func callback(_ error: (any Error)?) {
            let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
            let claimed = claim(result)
            claimed?.resume(with: result)
        }

        func cancel() {
            let result: Result<Void, any Error> = .failure(CancellationError())
            let claimed = claim(result)
            claimed?.resume(with: result)
        }

        private func claim(_ result: Result<Void, any Error>) -> CheckedContinuation<Void, any Error>? {
            state.withLock { state in
                guard state.result == nil else { return nil }
                state.result = result
                let continuation = state.continuation
                state.continuation = nil
                return continuation
            }
        }
    }

    /// Cancels only this control connection.
    public func close() { task.cancel(with: .goingAway, reason: nil) }

    private func mapped(_ error: any Error) -> any Error {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return V2ControlFailure.http(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        if let closed = Self.closeFailure(code: task.closeCode.rawValue, reason: task.closeReason) { return closed }
        return error
    }

    static func closeFailure(code: Int, reason: Data?) -> V2ControlFailure? {
        guard code != 0 else { return nil }
        let decoded = reason.flatMap { $0.count <= 128 ? String(data: $0, encoding: .utf8) : nil }
        let stable = decoded.flatMap { value in
            V2ErrorCode(rawValue: value) != nil || ["input_capacity", "transport_error", "goodbye", "replacement"].contains(value) ? value : nil
        }
        return .socketClosed(code: code, reason: stable)
    }
}
