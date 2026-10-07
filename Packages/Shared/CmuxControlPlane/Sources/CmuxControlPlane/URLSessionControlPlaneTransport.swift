public import Foundation

/// `URLSessionWebSocketTask` sockets for production.
public struct URLSessionControlPlaneTransport: ControlPlaneTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection {
        let task = session.webSocketTask(with: url, protocols: protocols)
        // Above the server's largest frame (a 1 MiB snapshot state plus its envelope).
        task.maximumMessageSize = 4 << 20
        task.resume()
        return URLSessionControlPlaneConnection(task: task)
    }
}
