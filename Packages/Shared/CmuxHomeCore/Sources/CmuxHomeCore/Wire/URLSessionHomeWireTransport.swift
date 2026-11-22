public import Foundation

/// The production ``HomeWireHTTP`` and ``HomeWireSocketConnecting`` over one
/// `URLSession`. The app makes one per server choice and passes it to
/// `WireHomeSource`.
public struct URLSessionHomeWireTransport: HomeWireHTTP, HomeWireSocketConnecting {
    private let session: URLSession

    /// - Parameter session: The session every request and socket uses
    ///   (default: an ephemeral one, so no cookie or cache outlives the app).
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HomeWireHTTPReply {
        let (data, response) = try await session.data(for: request)
        return Self.reply(data, response)
    }

    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> HomeWireHTTPReply {
        let (data, response) = try await session.upload(for: request, fromFile: file)
        return Self.reply(data, response)
    }

    public func download(_ request: URLRequest) async throws -> (status: Int, file: URL?) {
        let (location, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            try? FileManager.default.removeItem(at: location)
            return (status, nil)
        }
        // URLSession may delete its file once this returns: keep a copy the caller moves.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("home-wire-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: location, to: kept)
        return (status, kept)
    }

    public func connect(_ request: URLRequest) -> any HomeWireSocket {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionHomeWireSocket(task: task)
    }

    private static func reply(_ data: Data, _ response: URLResponse) -> HomeWireHTTPReply {
        let http = response as? HTTPURLResponse
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return HomeWireHTTPReply(status: http?.statusCode ?? 0, body: data, retryAfter: retryAfter,
                                 etag: http?.value(forHTTPHeaderField: "ETag"))
    }
}
