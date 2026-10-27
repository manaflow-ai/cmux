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
        // With streams and frames granted, the stream takes a client stream id before the request names it
        // (p05-ipc-145): its items then come as EVENT frames on that id, routed by header alone.
        let minted = admittedConnection?.transport.takingFramedStreams
        let frameStream = minted?.routeOnControlSequence(streamID: id, mintingFrameStream: true)
        var routed = minted
        do {
            _ = try await resourceRequest({ requestID in
                ResourceRequestEnvelope(id: requestID, operation: "session.events",
                                        params: SessionEventsWire.params(streamID: id, frameStream: frameStream),
                                        idempotencyKey: nil)
            }, as: SessionEventsWire.Opened.self, onTransport: { transport in
                // A reconnect during the handoff wait: the new connection opens its own stream.
                guard self.serial == serial else { throw DaemonError.notConnected }
                if let minted {
                    // The id is the minting connection's: another one never heard of it.
                    guard transport === minted else { throw DaemonError.notConnected }
                    return
                }
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

extension LineTransport {
    /// This transport when its handshake was granted client streams and frames (``DaemonWireGrants``): a
    /// stream opened on a client stream id then gets its items as EVENT frames. Nil otherwise.
    var takingFramedStreams: LineTransport? {
        let grants = wireGrants
        return grants.streams && grants.frames ? self : nil
    }
}

/// Wire shapes of the `session.events` stream request.
enum SessionEventsWire {
    /// A fresh `stream_<32 hex>` id.
    static func newStreamID() -> String {
        "stream_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The open's params: the v2 id, and the client stream id it maps to when one was taken.
    static func params(streamID: String, frameStream: UInt16?) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["stream_id": .string(streamID)]
        if let frameStream { params["stream"] = .number(Double(frameStream)) }
        return params
    }

    /// The `session.events` reply.
    struct Opened: Decodable {
        var streamID: String
        enum CodingKeys: String, CodingKey { case streamID = "stream_id" }
    }
}
