public import Foundation
import CmuxNextCompat
import CmuxNextWakeups

/// A `cmux.protocol/2` stream opened on the control connection and read apart from the event
/// path (the transport routes its lines by stream id), for a stream only one caller reads, such
/// as `tailnet.state`. `session.events` keeps its own path.
extension DaemonConnection {
    /// Opens `operation` as a stream: each `stream_item`'s `item` decoded as `T` on the reader thread
    /// (an item that is not one is skipped), until `stream_end`, the connection closing, or the
    /// reader stopping (which sends `stream.cancel`).
    ///
    /// Waits out a quiet handoff first, then registers, opens and cancels on that one transport, so
    /// a handoff in between never leaves the stream on one transport and its reader on another: the
    /// old transport's close ends the stream, and the caller opens it again on the new one.
    public func resourceStream<T: Decodable & Sendable>(operation: String, params: [String: JSONValue],
                                                         as type: T.Type) async throws -> AsyncStream<T> {
        await waitOutHandoff()
        guard let transport = ready?.transport else { throw DaemonError.notConnected }
        let id = SessionEventsWire.newStreamID()
        let (items, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let timeout = configuration.requestTimeout
        // Install cleanup before opening: timeout/cancellation can leave an accepted stream whose
        // opening reply never arrived. It still belongs to this transport and must be cancelled.
        continuation.onTermination = { _ in
            transport.unrouteStream(id)
            guard !transport.isClosed else { return }
            // task-owner: one best-effort cancel on the transport that opened the stream
            Task { try? await Self.send("stream.cancel", params: ["stream_id": .string(id)], on: transport, timeout: timeout) }
        }
        guard transport.routeStream(id, { line in
            guard let line, let parsed = ResourceStreamLine.parse(line) else { return continuation.finish() }
            guard let item = parsed else { return continuation.finish() }
            if let value = try? JSONDecoder().decode(T.self, from: item) { continuation.yield(value) }
        }) else { throw DaemonError.notConnected }
        var opening = params
        opening["stream_id"] = .string(id)
        do {
            try await Self.send(operation, params: opening, on: transport, timeout: configuration.requestTimeout)
        } catch {
            continuation.finish()
            throw error
        }
        return items
    }

    /// One resource request on `transport` itself (never whichever transport is current).
    private nonisolated static func send(_ operation: String, params: [String: JSONValue], on transport: LineTransport,
                                         timeout: Duration?) async throws {
        let slot = ReplySlot()
        // concurrency-allow: a bounded admission gate orders cancellation against this one
        // nonblocking transport submission; no await or external I/O occurs under this mutex.
        let admission = Mutex((cancelled: false, id: UInt64?.none))
        let timer = DemandTimer(owner: "ResourceStream.deadline")
        defer { timer.cancel() }
        let response = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let submitted = admission.withLock { state -> Result<UInt64, any Error> in
                guard !state.cancelled else { return .failure(CancellationError()) }
                let result = transport.submit(.reply(cmd: operation, slot)) { id in
                    try ResourceRequestEnvelope(id: id, operation: operation, params: params, idempotencyKey: nil).line()
                }
                if case .success(let id) = result { state.id = id }
                return result
            }
            if case .failure(let error) = submitted { throw error }
            if let timeout, case .success(let id) = submitted {
                timer.schedule(after: timeout) { transport.expire(id: id, after: timeout) }
            }
            return try await slot.value()
        } onCancel: {
            let id = admission.withLock { state in
                state.cancelled = true
                return state.id
            }
            slot.resolve(.failure(CancellationError()))
            if let id { transport.expire(id: id, after: .zero) }
        }
        _ = try ResourceRequestEnvelope.decodeResult(JSONValue.self, from: response.line)
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
