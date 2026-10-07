public import CmuxLink
public import Foundation

/// What carries WireGuard datagrams between a device and a host: in
/// production one WebRTC data channel (`ordered: false, maxRetransmits: 0`)
/// on B2's peer connection; in tests an in-memory lossy pipe.
///
/// Promises: datagrams may be lost, duplicated or reordered, never altered
/// in a way that authenticates; `send` suspends while the channel buffer is
/// full instead of growing it; `events` ends with exactly one `.closed`.
public protocol DatagramUnderlay: Sendable {
    /// `.p2p` for a host or server-reflexive ICE pair, `.turn` for a relay.
    var path: PathKind { get async }
    /// Largest datagram one message may carry (one SCTP chunk on WebRTC).
    var maxDatagramBytes: Int { get }
    /// Read by exactly one consumer.
    var events: AsyncStream<UnderlayEvent> { get }
    func send(_ datagram: Data) async throws
    func close() async
}
