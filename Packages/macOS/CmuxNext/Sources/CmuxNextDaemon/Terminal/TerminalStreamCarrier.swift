import Foundation

/// A daemon connection that carries terminal views as client streams
/// (`attach-streams-v1`, plans/cmux-next/app-daemon-connection-DESIGN.md): every
/// view attaches with one `attach-surface` on it and sends its commands on it,
/// with no connection or handshake of its own.
///
/// Get one from ``DaemonConnection/terminalStreams(device:)``; it is valid for
/// that connection's current transport only. When the transport ends, every
/// stream on it ends with `connectionLost` and views reattach on the next one.
public struct TerminalStreamCarrier: Sendable {
    let transport: LineTransport
    let identity: DaemonIdentity
    /// The connection negotiated binary frames (`attach-frames-v1`).
    let frames: Bool
}
