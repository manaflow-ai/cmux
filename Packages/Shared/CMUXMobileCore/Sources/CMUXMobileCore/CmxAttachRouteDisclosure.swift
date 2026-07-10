/// The disclosure boundary applied before serializing attach routes.
public enum CmxAttachRouteDisclosure: Equatable, Sendable {
    /// Same-account registry, presence, or local persistence.
    case authenticated
    /// An unauthenticated network status response.
    case publicStatus
    /// A scannable pairing payload.
    case pairingQRCode
    /// The paired-Mac server backup.
    case pairedMacCloudBackup
}
