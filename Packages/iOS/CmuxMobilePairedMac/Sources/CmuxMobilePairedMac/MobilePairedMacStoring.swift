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
    ///   - teamID: Stack team this pairing belongs to; stamped on the row so the
    ///     local list can be scoped per team. `nil` leaves the team unset (anonymous
    ///     / pre-team pairing).
    ///   - now: Timestamp used for `lastSeenAt` (and `createdAt` on first insert).
    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Load all paired Macs, optionally scoped to a Stack user and team.
    /// - Parameters:
    ///   - stackUserID: When set, returns only Macs owned by that user.
    ///   - teamID: When set, returns only Macs in that team (plus team-less legacy
    ///     rows, so an upgrade never hides existing hosts). `nil` = every team.
    /// - Returns: Paired Macs ordered by `lastSeenAt` descending.
    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac]

    /// Return the active paired Mac for a scope, if any.
    /// - Parameters:
    ///   - stackUserID: When set, scopes the lookup to that user.
    ///   - teamID: When set, scopes the lookup to that team (plus team-less rows).
    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac?

    /// Mark the given Mac as the single active pairing in one owner scope.
    /// - Parameters:
    ///   - macDeviceID: Mac to activate.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this activation belongs to, if any.
    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws

    /// Clear the active pairing for one visible owner scope.
    /// - Parameters:
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team whose visible rows should be cleared. When set,
    ///     team-less legacy rows are cleared too because they are visible in that
    ///     team scope.
    func clearActive(stackUserID: String?, teamID: String?) async throws

    /// Set the user's per-Mac customizations (synced per user). Leaves the
    /// Mac-reported name, routes, and active flag untouched, and bumps
    /// `lastSeenAt` so the change is the freshest write for LWW sync.
    /// - Parameters:
    ///   - macDeviceID: Mac to customize.
    ///   - customName: Name override, or `nil` to clear it.
    ///   - customColor: Color override (`"palette:<n>"` / `"#RRGGBB"`), or `nil`.
    ///   - customIcon: Icon override (SF Symbol name or emoji), or `nil`.
    ///   - now: Timestamp for `lastSeenAt`.
    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Set the device-local iroh EndpointId trust pin. Leaves routes,
    /// customization, active state, and `lastSeenAt` untouched.
    /// - Parameters:
    ///   - macDeviceID: Mac whose iroh identity is trusted.
    ///   - endpointID: iroh EndpointId to trust for this Mac.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this trust pin belongs to, if any.
    ///   - now: Timestamp supplied by callers for audit symmetry; implementations
    ///     must not bump `lastSeenAt` from this value.
    func setPinnedIrohEndpointID(
        macDeviceID: String,
        endpointID: String,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Remove a single paired Mac in one owner scope.
    /// - Parameters:
    ///   - macDeviceID: Mac to forget.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this pairing belongs to, if any.
    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws

    /// Remove all paired Macs.
    func removeAll() async throws
}

extension MobilePairedMacStoring {
    /// Insert or update a paired Mac with an explicit timestamp but no team scope
    /// (`teamID: nil`). Keeps existing call sites compiling; the team-aware caller
    /// (``BackingUpPairedMacStore``) injects the team via the full requirement.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: nil,
            now: now
        )
    }

    /// Insert or update a paired Mac, timestamping with the current `Date` and no
    /// team scope.
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
            teamID: nil,
            now: Date()
        )
    }

    /// Load all paired Macs for a Stack user across every team.
    public func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        try await loadAll(stackUserID: stackUserID, teamID: nil)
    }

    /// Load all paired Macs across every Stack user and team scope.
    public func loadAll() async throws -> [MobilePairedMac] {
        try await loadAll(stackUserID: nil, teamID: nil)
    }

    /// Return the active paired Mac for a Stack user across every team, if any.
    public func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        try await activeMac(stackUserID: stackUserID, teamID: nil)
    }

    /// Return the active paired Mac across every Stack user and team scope, if any.
    public func activeMac() async throws -> MobilePairedMac? {
        try await activeMac(stackUserID: nil, teamID: nil)
    }

    /// Mark the given Mac active without an explicit owner scope. Implementations
    /// may use this only for legacy/unscoped rows; team-aware callers should pass
    /// the captured scope through the full requirement.
    public func setActive(macDeviceID: String) async throws {
        try await setActive(macDeviceID: macDeviceID, stackUserID: nil, teamID: nil)
    }

    /// Persist customizations without an explicit owner scope. Team-aware callers
    /// should pass the captured scope through the full requirement.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        now: Date
    ) async throws {
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: nil,
            teamID: nil,
            now: now
        )
    }

    /// Persist an iroh trust pin without an explicit owner scope. Team-aware
    /// callers should pass the captured scope through the full requirement.
    public func setPinnedIrohEndpointID(
        macDeviceID: String,
        endpointID: String,
        now: Date
    ) async throws {
        try await setPinnedIrohEndpointID(
            macDeviceID: macDeviceID,
            endpointID: endpointID,
            stackUserID: nil,
            teamID: nil,
            now: now
        )
    }

    /// Remove a Mac without an explicit owner scope. Team-aware callers should
    /// pass the captured scope through the full requirement.
    public func remove(macDeviceID: String) async throws {
        try await remove(macDeviceID: macDeviceID, stackUserID: nil, teamID: nil)
    }
}
