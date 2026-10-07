public import Foundation

/// `URLSessionWebSocketTask` sockets for production.
public struct URLSessionControlPlaneTransport: ControlPlaneTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, protocols: [String]) async throws -> any ControlPlaneConnection {
        let task = session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionControlPlaneConnection(task: task)
    }
}
