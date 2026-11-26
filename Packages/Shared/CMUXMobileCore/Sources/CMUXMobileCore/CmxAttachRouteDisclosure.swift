/// The disclosure boundary applied before serializing attach routes.
public enum CmxAttachRouteDisclosure: Equatable, Sendable {
    /// Same-account registry, presence, or local persistence.
    case authenticated
    /// Cloud rendezvous shared with other authenticated devices. Iroh identity
    /// and relay bootstrap are retained; direct path and network-profile
    /// metadata stay device-local.
    case cloudRendezvous
    /// An unauthenticated network status response.
    case publicStatus
    /// A scannable pairing payload.
    case pairingQRCode
    /// The paired-Mac server backup. Iroh uses the same relay-only boundary as
    /// cloud rendezvous.
    case pairedMacCloudBackup
}
