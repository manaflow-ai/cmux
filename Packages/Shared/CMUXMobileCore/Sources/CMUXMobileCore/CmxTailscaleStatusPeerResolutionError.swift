/// Fail-closed errors produced while binding a MagicDNS input to one local
/// Tailscale control-plane peer record.
public enum CmxTailscaleStatusPeerResolutionError: Error, Equatable, Sendable {
    /// The requested value was not a syntactically valid fully qualified `*.ts.net` name.
    case invalidMagicDNSName
    /// The status command did not return a bounded JSON object.
    case malformedStatus
    /// The local Tailscale backend was not running when the snapshot was read.
    case statusNotRunning
    /// No peer in the status snapshot had the exact normalized DNS name.
    case peerNotFound
    /// More than one status record claimed the exact normalized DNS name.
    case ambiguousPeer
    /// The exact name identified this device rather than a remote peer.
    case localDeviceNotAllowed
    /// The matched record had no numeric addresses.
    case missingPeerAddresses
    /// At least one address in the matched record was not a Tailscale peer address.
    case invalidPeerAddress
}
