public import Foundation

/// One HTTP exchange with a `cmux.wire/1` server: the seam `WireHomeSource`
/// sends every `POST /v1/ops`, `POST /v1/read`, `GET /v1/selfhost/info` and
/// attachment request through. Production uses ``URLSessionHomeWireTransport``;
/// tests pass a fake that records the requests and answers from a script
/// (it implements ``send(_:)`` only: uploads and downloads default to it).
public protocol HomeWireHTTP: Sendable {
    /// Sends `request` and returns the status and body. Throws only when no
    /// answer came (a `URLError`); an error status is an answer.
    func send(_ request: URLRequest) async throws -> HomeWireHTTPReply

    /// Sends `request` with the file at `file` as its body (an attachment PUT).
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> HomeWireHTTPReply

    /// Downloads `request`'s body into a new temporary file; the caller
    /// moves it. Returns the status and that file (nil for an error status).
    func download(_ request: URLRequest) async throws -> (status: Int, file: URL?)
}

extension HomeWireHTTP {
    public func upload(_ request: URLRequest, fromFile file: URL) async throws -> HomeWireHTTPReply {
        var request = request
        request.httpBody = try Data(contentsOf: file)
        return try await send(request)
    }

    public func download(_ request: URLRequest) async throws -> (status: Int, file: URL?) {
        let reply = try await send(request)
        guard (200...299).contains(reply.status) else { return (reply.status, nil) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("home-wire-\(UUID().uuidString)")
        try reply.body.write(to: file, options: .atomic)
        return (reply.status, file)
    }
}
