public import Foundation

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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Cancels only this control connection.
    public func close() { task.cancel(with: .goingAway, reason: nil) }

    private func mapped(_ error: any Error) -> any Error {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return V2ControlFailure.http(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        return error
    }
}
