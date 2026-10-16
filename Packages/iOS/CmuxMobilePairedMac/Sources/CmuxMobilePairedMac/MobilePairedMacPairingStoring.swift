public import CMUXMobileCore
public import Foundation

/// A paired-Mac store that commits explicit pairing metadata and endpoint grants atomically.
public protocol MobilePairedMacPairingStoring: MobilePairedMacStoring {
    /// Saves a verified pairing and its user-authorized routes as one operation.
    ///
    /// - Parameters:
    ///   - macDeviceID: Authenticated device identity.
    ///   - displayName: Name reported by the authenticated host.
    ///   - routes: Destinations explicitly entered by the user.
    ///   - instanceTag: Exact app instance being paired.
    ///   - markActive: Whether to make this pairing active.
    ///   - stackUserID: Account owning the pairing and grants.
    ///   - teamID: Team owning the pairing and grants.
    ///   - now: Timestamp for the pairing metadata.
    /// - Throws: A storage error, leaving both metadata and grants unchanged.
    func upsertWithUserTailscaleAuthorization(
        macDeviceID: String, displayName: String?, routes: [CmxAttachRoute],
        instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date
    ) async throws
}
