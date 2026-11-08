/// Request categories tracked while a cloud manual-mirror handshake is in flight.
///
/// Resize requests retain the exact grid they carried. A response can arrive
/// after a visibility transition has reset the scheduler, so acknowledging by
/// request kind alone could accidentally retire a newer grid.
public enum CloudTuiManualMirrorRequestKind: Equatable, Sendable {
    case identify
    case clientInfo
    case attach
    case resize(CloudTuiManualIOGrid)
    case claim
    /// The watchdog's liveness probe; any answer proves the stream is alive.
    case ping
    /// A relay sub-view report (a phone behind this Mac); the answer names
    /// the host participant id for the view key.
    case relayView(String)
    /// A shared-sizing mutation or `get-size-state`; the answer may carry state.
    case sizing
}
