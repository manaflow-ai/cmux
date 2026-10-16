import Foundation

/// Holds one WebSocket and serializes viewing revisions across timer/UI callers.
actor WorkspacePresenceSocket: WorkspacePresenceConnection {
    // URLSession and URLSessionWebSocketTask are Sendable Foundation handles.
    private nonisolated let session: URLSession
    private nonisolated let socket: URLSessionWebSocketTask
    private var revision: UInt64 = 0

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: WorkspacePresenceRedirectDelegate(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 512 * 1024
        self.socket = socket
        socket.resume()
    }

    deinit { close() }

    func receive() async throws -> WorkspacePresenceSnapshot {
        do {
            return try await withTaskCancellationHandler {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: throw WorkspacePresenceError.invalidSnapshot
                }
                return try JSONDecoder().decode(WorkspacePresenceSnapshot.self, from: data)
            } onCancel: { close() }
        } catch {
            if let response = socket.response as? HTTPURLResponse, response.statusCode == 429 {
                let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 15
                throw WorkspacePresenceError.retryAfter(min(max(delay, 1), 300))
            }
            throw error
        }
    }

    func sendViewing(_ active: Bool, revision next: UInt64) async throws {
        guard next >= revision else { return }
        revision = next
        try await socket.send(.string(active ? #"{"type":"view","active":true}"# : #"{"type":"view","active":false}"#))
    }

    nonisolated func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
