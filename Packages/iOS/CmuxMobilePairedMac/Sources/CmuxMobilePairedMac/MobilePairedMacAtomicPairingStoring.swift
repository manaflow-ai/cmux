public import CMUXMobileCore

/// Optional capability for stores that can commit a user Tailscale grant and
/// its per-device connection method in one transaction.
public protocol MobilePairedMacAtomicPairingStoring: MobilePairedMacStoring {
    /// Atomically record the exact user-authorized routes and method for one
    /// paired-Mac row. Production decorators forward this to their inner store.
    func authorizeUserTailscaleRoutesAndSetConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) async throws
}
