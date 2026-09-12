/// The app transport involved in a diagnostic event.
///
/// Raw values are stable export vocabulary. Append new cases; never renumber
/// an existing case.
public enum DiagnosticTransportKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case iroh = 1
    case tailscale = 2
    case websocket = 3
    case debugLoopback = 4
    case nextTransport = 5

    /// Maps a pairing-route transport without preserving its address or other
    /// route metadata.
    public init(_ kind: CmxAttachTransportKind) {
        switch kind {
        case .iroh:
            self = .iroh
        case .tailscale:
            self = .tailscale
        case .websocket:
            self = .websocket
        case .debugLoopback:
            self = .debugLoopback
        case .nextTransport:
            self = .nextTransport
        }
    }
}
