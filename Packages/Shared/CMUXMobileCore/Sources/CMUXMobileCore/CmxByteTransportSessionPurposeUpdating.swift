/// Optional role update for a connected transport whose underlying peer
/// session stays live while ownership moves between foreground and background.
public protocol CmxByteTransportSessionPurposeUpdating: CmxByteTransport {
    /// Reclassifies the live transport for foreground or background tuning.
    func updateSessionPurpose(_ purpose: CmxTransportSessionPurpose) async
}
