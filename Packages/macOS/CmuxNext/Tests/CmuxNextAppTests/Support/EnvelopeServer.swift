import Foundation
import Network
import os

/// A one-purpose HTTP server on 127.0.0.1 that stands in for Sentry's ingest in end-to-end
/// tests: it answers every POST with 200 and keeps each body (gunzipped when the client sent
/// `Content-Encoding: gzip`, as the Sentry SDK does).
nonisolated final class EnvelopeServer: Sendable {
    // NWListener is documented thread-safe; it is used only through its queue.
    private nonisolated(unsafe) let listener: NWListener
    private let queue = DispatchQueue(label: "envelope-server")
    private let bodies: AsyncStream<Data>
    private let received: AsyncStream<Data>.Continuation

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        (bodies, received) = AsyncStream.makeStream(of: Data.self)
    }

    /// Starts listening; returns the port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { [listener] state in
                let port: UInt16? = if case .ready = state { listener.port?.rawValue } else { nil }
                let failure: NWError? = if case let .failed(error) = state { error } else { nil }
                guard port != nil || failure != nil, resumed.claim() else { return }
                if let port { continuation.resume(returning: port) } else if let failure { continuation.resume(throwing: failure) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    /// The first body received, or nil when none came within `timeout` (a bounded test deadline).
    func firstEnvelope(timeout: Duration) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { [bodies] in await bodies.first { _ in true } }
            group.addTask {
                // Deadline only: the other task returns as soon as a body arrives.
                try? await ContinuousClock().sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequestParts(buffer) {
                self.received.yield(request.body)
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }
}

/// A complete HTTP/1.1 request with a `Content-Length` body, or nil while bytes are missing.
private nonisolated struct HTTPRequestParts {
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self).lowercased()
        let fields = head.split(separator: "\r\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let length = fields.first { $0.0 == "content-length" }.flatMap { Int($0.1) } ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let raw = data[bodyStart..<(bodyStart + length)]
        let gzip = fields.contains { $0.0 == "content-encoding" && $0.1.contains("gzip") }
        body = gzip ? Self.gunzip(Data(raw)) ?? Data(raw) : Data(raw)
    }

    /// A gzip member with no optional header fields (what zlib's gzip writer makes).
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b,
              data[data.startIndex + 3] == 0 else { return nil }
        let deflate = data[(data.startIndex + 10)..<(data.endIndex - 8)]
        return try? (Data(deflate) as NSData).decompressed(using: .zlib) as Data
    }
}

/// Lock carve-out: a one-shot resume guard for the listener's state callback.
private nonisolated final class ResumeOnce: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)
    func claim() -> Bool { claimed.withLock { was in defer { was = true }; return !was } }
}
