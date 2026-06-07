public import CMUXMobileCore
public import Foundation

/// Persistence seam for paired Macs, conformed by ``MobilePairedMacStore``.
///
/// Higher layers depend on `any MobilePairedMacStoring` and the concrete actor
/// is constructed once at the app composition root, so the store can be replaced
/// with an in-memory double in tests and previews without a singleton factory.
public protocol MobilePairedMacStoring: Sendable {
    /// Insert or update a paired Mac and its routes.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the Mac.
    ///   - displayName: Optional human-readable Mac name.
    ///   - routes: Attach routes advertised by the Mac.
    ///   - markActive: When `true`, makes this the active pairing for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - now: Timestamp used for `lastSeenAt` (and `createdAt` on first insert).
    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws

    /// Load all paired Macs, optionally scoped to a Stack user.
    /// - Parameter stackUserID: When set, returns only Macs owned by that user.
    /// - Returns: Paired Macs ordered by `lastSeenAt` descending.
    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac]

    /// Return the active paired Mac for a scope, if any.
    /// - Parameter stackUserID: When set, scopes the lookup to that user.
    func activeMac(stackUserID: String?) async throws -> MobilePairedMac?

    /// Mark the given Mac as the single active pairing.
    /// - Parameter macDeviceID: Mac to activate.
    func setActive(macDeviceID: String) async throws

    /// Remove a single paired Mac.
    /// - Parameter macDeviceID: Mac to forget.
    func remove(macDeviceID: String) async throws

    /// Remove all paired Macs.
    func removeAll() async throws
}

extension MobilePairedMacStoring {
    /// Insert or update a paired Mac, timestamping with the current `Date`.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the Mac.
    ///   - displayName: Optional human-readable Mac name.
    ///   - routes: Attach routes advertised by the Mac.
    ///   - markActive: When `true`, makes this the active pairing for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?
    ) async throws {
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            markActive: markActive,
            stackUserID: stackUserID,
            now: Date()
        )
    }

    /// Load all paired Macs across every Stack user scope.
    public func loadAll() async throws -> [MobilePairedMac] {
        try await loadAll(stackUserID: nil)
    }

    /// Return the active paired Mac across every Stack user scope, if any.
    public func activeMac() async throws -> MobilePairedMac? {
        try await activeMac(stackUserID: nil)
    }
}
