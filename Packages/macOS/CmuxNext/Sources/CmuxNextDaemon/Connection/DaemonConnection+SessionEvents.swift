import Foundation

/// The `session.events` stream that carries the daemon's state resources
/// (closed history, workspace status, ephemeral workspaces, screen metadata
/// and groups, tab records, terminal progress) to `DaemonStore.sessionState`.
///
/// Opened on every connect, after the handshake, without blocking it. Its
/// lines arrive on the control socket between the raw events and travel
/// through the same ordered event stream (`DaemonEvent.sessionState`). A
/// daemon whose snapshot lists no state resources predates them: the
/// stream is cancelled and the app keeps its own paths. A stream that ends
/// with `gap` (the app fell behind) is opened again for a fresh snapshot.
extension DaemonConnection {
    /// A fresh `stream_<32 hex>` id.
    static func newStreamID() -> String {
        "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    struct StreamOpened: Decodable {
        var streamID: String
        enum CodingKeys: String, CodingKey { case streamID = "stream_id" }
    }

    /// Opens `session.events` on connection `serial`. A daemon or fake that
    /// cannot serve it leaves the app on its own paths.
    func openSessionEvents(serial: UInt64) async {
        guard configuration.sessionEvents, isReady, self.serial == serial else { return }
        let id = Self.newStreamID()
        sessionStream = id
        do {
            _ = try await resourceRequest({ requestID in
                ResourceRequestEnvelope(id: requestID, operation: "session.events",
                                        params: ["stream_id": .string(id)], idempotencyKey: nil)
            }, as: StreamOpened.self)
        } catch {
            if sessionStream == id { sessionStream = nil }
        }
    }

    /// Routes stream lifecycle the reader saw: cancel a stream the daemon
    /// serves no state on, reopen one that ended with `gap`.
    func sessionStreamEvent(_ item: SessionStreamItem, serial: UInt64) async {
        guard self.serial == serial else { return }
        switch item {
        case .unsupported:
            guard let id = sessionStream else { return }
            sessionStream = nil
            _ = try? await resourceRequest({ requestID in
                ResourceRequestEnvelope(id: requestID, operation: "stream.cancel", params: ["stream": .string(id)],
                                        idempotencyKey: nil)
            }, as: JSONValue.self)
        case .ended(let reason):
            sessionStream = nil
            if reason == "gap" { await openSessionEvents(serial: serial) }
        case .snapshot, .delta:
            break
        }
    }
}
