import Foundation

/// The `session.events` stream that carries the daemon's state resources
/// (closed history, workspace status, ephemeral workspaces, screen metadata
/// and groups, tab records, terminal progress) to `DaemonStore.session`.
///
/// Opened after the handshake, without blocking it, when the daemon's
/// `identify` advertises `state-resources-v1`. Its lines arrive on the
/// control socket between the raw events and travel through the same
/// ordered event stream (`DaemonEvent.sessionState`). A stream that ends with
/// `gap` (the app fell behind) is opened again for a fresh snapshot.
extension DaemonConnection {
    /// True when this connection mirrors the state resources (it opens
    /// `session.events`); otherwise the store never learns about them.
    public nonisolated var mirrorsSessionState: Bool { configuration.sessionEvents }

    /// Opens `session.events` on connection `serial` when the daemon serves
    /// the state resources.
    func openSessionEvents(serial: UInt64) async {
        guard configuration.sessionEvents, isReady, self.serial == serial,
              identity?.supports(DaemonCapability.stateResources.rawValue) == true else { return }
        let id = SessionEventsWire.newStreamID()
        sessionStream = id
        var routed: LineTransport?
        do {
            _ = try await resourceRequest({ requestID in
                ResourceRequestEnvelope(id: requestID, operation: "session.events",
                                        params: ["stream_id": .string(id)], idempotencyKey: nil)
            }, as: SessionEventsWire.Opened.self, onTransport: { transport in
                // A reconnect during the handoff wait: the new connection opens its own stream.
                guard self.serial == serial else { throw DaemonError.notConnected }
                // Its items ride the daemon's reply FIFO: they count in the event barrier
                // of the transport that carries the request.
                transport.routeOnControlSequence(streamID: id)
                routed = transport
            })
        } catch {
            routed?.endControlSequence(streamID: id)
            guard self.serial == serial, sessionStream == id else { return }
            sessionStream = nil
            // No stream: waiters for the first snapshot stop waiting.
            if let sequence = eventSequence() {
                yieldEvent(DaemonEventEnvelope(sequence: sequence, event: .sessionState(.ended(reason: "failed"))))
            }
        }
    }

    /// Routes stream lifecycle the reader saw: reopen a stream that ended
    /// with `gap`.
    func sessionStreamEvent(_ item: SessionStreamItem, serial: UInt64) async {
        guard self.serial == serial else { return }
        switch item {
        case .ended(let reason):
            sessionStream = nil
            if reason == "gap" { await openSessionEvents(serial: serial) }
        case .snapshot, .delta:
            break
        }
    }
}

/// Wire shapes of the `session.events` stream request.
enum SessionEventsWire {
    /// A fresh `stream_<32 hex>` id.
    static func newStreamID() -> String {
        "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The `session.events` reply.
    struct Opened: Decodable {
        var streamID: String
        enum CodingKeys: String, CodingKey { case streamID = "stream_id" }
    }
}
