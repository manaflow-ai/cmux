import Foundation

public extension AgentPaneModel {
    /// The local Unix socket used for read-only session metadata exports. Nil for a remote chat or
    /// before the handshake, so callers cannot accidentally route a local read to another host.
    var sessionCopySocketPath: String? { transport.acpmuxSocket }
}
