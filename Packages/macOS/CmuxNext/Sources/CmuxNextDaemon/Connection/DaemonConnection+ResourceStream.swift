public import Foundation

/// A `cmux.protocol/2` stream opened on the control connection and read apart from the event
/// path (the transport routes its lines by stream id), for a stream only one caller reads, such
/// as `tailnet.state`. `session.events` keeps its own path.
extension DaemonConnection {
    /// Opens `operation` as a stream: each `stream_item`'s `item` decoded as `T` on the reader thread
    /// (an item that is not one is skipped), until `stream_end`, the connection closing, or the
    /// reader stopping (which sends `stream.cancel`).
    public func resourceStream<T: Decodable & Sendable>(operation: String, params: [String: JSONValue],
                                                         as type: T.Type) async throws -> AsyncStream<T> {
        guard let transport = ready?.transport else { throw DaemonError.notConnected }
        let id = SessionEventsWire.newStreamID()
        let (items, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard transport.routeStream(id, { line in
            guard let line, let parsed = ResourceStreamLine.parse(line) else { return continuation.finish() }
            guard let item = parsed else { return continuation.finish() }
            if let value = try? JSONDecoder().decode(T.self, from: item) { continuation.yield(value) }
        }) else { throw DaemonError.notConnected }
        var opening = params
        opening["stream_id"] = .string(id)
        let request = opening
        do {
            _ = try await resourceRequest({ requestID in
                ResourceRequestEnvelope(id: requestID, operation: operation, params: request, idempotencyKey: nil)
            }, as: SessionEventsWire.Opened.self)
        } catch {
            transport.unrouteStream(id)
            continuation.finish()
            throw error
        }
        continuation.onTermination = { [weak self] _ in
            transport.unrouteStream(id)
            // task-owner: one best-effort cancel of a stream the reader dropped
            Task { await self?.cancelResourceStream(id) }
        }
        return items
    }

    /// `stream.cancel` for a stream this connection opened; a closed connection needs none.
    private func cancelResourceStream(_ id: String) async {
        guard isReady else { return }
        _ = try? await resourceRequest({ requestID in
            ResourceRequestEnvelope(id: requestID, operation: "stream.cancel", params: ["stream_id": .string(id)], idempotencyKey: nil)
        }, as: JSONValue.self)
    }
}

/// One stream line: `.some(item)` for a `stream_item`, `.some(nil)` for `stream_end`, nil when
/// the line is not a stream line at all (it ends the reader too).
enum ResourceStreamLine {
    static func parse(_ line: Data) -> Data?? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        guard type == "stream_item" else { return .some(nil) }
        guard let item = object["item"], JSONSerialization.isValidJSONObject(item),
              let data = try? JSONSerialization.data(withJSONObject: item) else { return .some(nil) }
        return .some(data)
    }
}
