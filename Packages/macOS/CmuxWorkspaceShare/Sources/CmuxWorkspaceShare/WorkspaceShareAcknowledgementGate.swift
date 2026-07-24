/// Orders application-level acknowledgements after accepted server payloads.
///
/// Sequence numbers count every WebSocket frame received on one connection.
/// Requiring adjacent sequence numbers makes dropped or unsupported frames fail
/// closed: an `ack-request` can acknowledge only its immediately preceding
/// logical payload.
public struct WorkspaceShareAcknowledgementGate: Sendable {
    private var acceptedPayloadSequence: UInt64?

    /// Creates an empty gate.
    public init() {}

    /// Clears credit when a socket opens or reconnects.
    public mutating func connectionOpened() {
        acceptedPayloadSequence = nil
    }

    /// Records whether a decoded logical payload entered bounded application state.
    public mutating func recordPayload(accepted: Bool, sequence: UInt64) {
        acceptedPayloadSequence = accepted ? sequence : nil
    }

    /// Consumes credit and returns the nonce only for the adjacent marker.
    public mutating func acknowledgement(
        for nonce: ShareAckNonce,
        sequence: UInt64
    ) -> ShareAckNonce? {
        defer { acceptedPayloadSequence = nil }
        guard let acceptedPayloadSequence,
              acceptedPayloadSequence < UInt64.max,
              sequence == acceptedPayloadSequence + 1 else {
            return nil
        }
        return nonce
    }
}
