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

/// Raised when a wrapper is asked to persist a security-sensitive pairing
/// mutation but its inner store does not provide a transaction boundary.
public enum MobilePairedMacAtomicPairingError: Error, Equatable, Sendable {
    case unavailable
}

extension MobilePairedMacAtomicPairingStoring {
    /// Forward a combined grant/method mutation only to an inner store that
    /// explicitly provides the same atomic capability. There is intentionally
    /// no two-write fallback: a grant without its Tailscale-only method would
    /// widen the reconnect surface after a partial failure.
    public func authorizeUserTailscaleRoutesAndSetConnectionMethod(
        forwardingTo inner: any MobilePairedMacStoring,
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute],
        rawValue: String
    ) async throws {
        guard let atomicInner = inner as? any MobilePairedMacAtomicPairingStoring else {
            throw MobilePairedMacAtomicPairingError.unavailable
        }
        try await atomicInner.authorizeUserTailscaleRoutesAndSetConnectionMethod(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            routes: routes,
            rawValue: rawValue
        )
    }
}
