public import CMUXMobileCore
public import CmuxMobilePairedMac
import CmuxMobileShellModel
public import Foundation

/// Overlays the demonstration computer onto the persisted paired-Mac list
/// while the signed-in account is server-flagged for demonstration content.
///
/// Sits OUTSIDE the build-scope/team/backup decorators, so the demo row is
/// never written to SQLite, never rides account backup, and disappears the
/// moment the flag turns off — while every consumer of the store (the
/// Computers list, reconnect flows, the device-registry route lookup) sees it
/// through the same `loadAll` data path a real pairing uses. Mutations
/// addressed to the demo record are swallowed: there is nothing durable to
/// mutate, and forwarding them would touch real rows.
public struct DemoContentPairedMacStore: MobilePairedMacStoring {
    private let inner: any MobilePairedMacStoring
    /// Whether the signed-in account is currently demonstration-flagged.
    private let isEnabled: @Sendable () async -> Bool
    private let now: @Sendable () -> Date

    /// Wraps a fully composed paired-Mac store.
    /// - Parameters:
    ///   - inner: The production store stack (build-scoped, team-scoped, backed up).
    ///   - isEnabled: Live activation check, read on every load.
    ///   - now: Clock for the synthesized row's timestamps; injected for tests.
    public init(
        inner: any MobilePairedMacStoring,
        isEnabled: @escaping @Sendable () async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.isEnabled = isEnabled
        self.now = now
    }

    private func isDemoDeviceID(_ macDeviceID: String) -> Bool {
        cmxCanonicalDeviceID(macDeviceID)
            == cmxCanonicalDeviceID(MobileDemoContentCatalog.macDeviceID)
    }

    /// The synthesized demonstration row, stamped with the caller's scope so
    /// user/team-scoped loads keep it visible for the flagged account.
    private func demoRecord(stackUserID: String?, teamID: String?) -> MobilePairedMac {
        // "Seen a few minutes ago": recent enough to read as alive, old
        // enough that a real Mac's fresher activity sorts first.
        let seenAt = now().addingTimeInterval(-5 * 60)
        return MobilePairedMac(
            macDeviceID: MobileDemoContentCatalog.macDeviceID,
            displayName: MobileDemoContentCatalog.displayName,
            routes: [],
            createdAt: seenAt,
            lastSeenAt: seenAt,
            isActive: false,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    // MARK: Loads (overlay)

    public func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        var loaded = try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
        guard await isEnabled() else { return loaded }
        // Defensive: never duplicate the row if a demo id somehow persisted.
        loaded.removeAll { isDemoDeviceID($0.macDeviceID) }
        loaded.append(demoRecord(stackUserID: stackUserID, teamID: teamID))
        return loaded
    }

    public func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        if isDemoDeviceID(macDeviceID) {
            guard await isEnabled() else { return [] }
            return [demoRecord(stackUserID: stackUserID, teamID: nil)]
        }
        return try await inner.loadAllInstances(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID
        )
    }

    public func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        // The demo row is never active, so the inner answer is authoritative.
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    // MARK: Mutations (demo-addressed calls are swallowed)

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    @discardableResult
    public func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        guard !isDemoDeviceID(macDeviceID) else { return false }
        return try await inner.upsertIfNewer(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    @discardableResult
    public func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        guard !isDemoDeviceID(macDeviceID) else { return false }
        return try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    public func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    public func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.removeExactScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func removeExactScopes(_ scopes: [MobilePairedMacExactScope]) async throws {
        let forwarded = scopes.filter { !isDemoDeviceID($0.macDeviceID) }
        guard !forwarded.isEmpty else { return }
        try await inner.removeExactScopes(forwarded)
    }

    public func removeAll() async throws {
        try await inner.removeAll()
    }

    public func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setConnectionMethod(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            rawValue: rawValue,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func setDirectAddresses(
        macDeviceID: String,
        instanceTag: String?,
        rawJSON: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.setDirectAddresses(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            rawJSON: rawJSON,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    public func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        guard !isDemoDeviceID(macDeviceID) else { return }
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            routes: routes
        )
    }
}
