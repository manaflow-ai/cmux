/// Request categories tracked while a cloud manual-mirror handshake is in flight.
///
/// Resize requests retain the exact grid they carried. A response can arrive
/// after a visibility transition has reset the scheduler, so acknowledging by
/// request kind alone could accidentally retire a newer grid.
enum CloudTuiManualMirrorRequestKind: Equatable, Sendable {
    case identify
    case clientInfo
    case attach
    case resize(CloudTuiManualIOGrid)
    case claim
}
