import Foundation

/// Owns one private, uncached URLSession and cancels a blocked receive with its Swift task.
actor CloudAuthorityURLSocket: CloudAuthorityWireSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var closed = false

    init(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: InstallAuthRedirectRefusal(), delegateQueue: nil)
        self.session = session
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 8 << 20
        socket.resume()
    }

    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        let socket = socket
        return try await withTaskCancellationHandler {
            let message = try await socket.receive()
            try Task.checkCancellation()
            switch message {
            case let .string(text): return Data(text.utf8)
            case let .data(data): return data
            @unknown default: throw CloudAuthorityWireLease.Failure.frame
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed, data.count <= 8 << 20 else { throw CancellationError() }
        try Task.checkCancellation()
        try await socket.send(.data(data))
    }

    func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
