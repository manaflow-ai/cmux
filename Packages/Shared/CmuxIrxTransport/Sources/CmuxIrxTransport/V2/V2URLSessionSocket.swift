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
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch { throw mapped(error) }
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
