/// One live connection on one path, produced by a carrier.
///
/// Promises (checked by `LinkConformanceSuite`):
/// - frames on a `reliableOrdered` lane arrive once and in order while the
///   transport lives; other lanes may lose or reorder;
/// - `send` back-pressures (suspends) rather than dropping reliable frames;
/// - `events` ends with exactly one `.closed`;
/// - `close()` is graceful: reliable frames accepted by `send` before it
///   reach the peer before the peer sees `.closed(.remote)`;
/// - a path move without a drop is reported as `.pathChanged`;
/// - `connect` and `send` honor task cancellation.
public protocol LinkTransport: Sendable {
    var path: LinkPath { get async }
    var capabilities: TransportCapabilities { get }
    /// Read by exactly one consumer (the session or the host).
    var events: AsyncStream<TransportEvent> { get }
    func send(_ frame: TransportFrame) async throws
    /// Publishes a media track to the peer, which receives it as
    /// `.mediaTrack`. Throws when `capabilities.carriesMedia` is false.
    func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle
    func close() async
}
