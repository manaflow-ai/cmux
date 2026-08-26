internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import Foundation

/// Applies one build-compatibility policy to every paired-Mac store operation.
struct MobileMacCompatiblePairedMacStore: MobilePairedMacStoring {
    private let inner: any MobilePairedMacStoring
    private let policy: MobileMacBuildCompatibilityPolicy

    init(
        inner: any MobilePairedMacStoring,
        policy: MobileMacBuildCompatibilityPolicy
    ) {
        self.inner = inner
        self.policy = policy
    }

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
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
    func upsertIfNewer(
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
        guard isCompatible(instanceTag: instanceTag) else { return false }
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
    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let instanceTag: String?
        switch condition {
        case .matchingInstanceTag(let expectedInstanceTag):
            instanceTag = expectedInstanceTag
        case .unclaimed:
            instanceTag = nil
        }
        guard isCompatible(instanceTag: instanceTag) else { return false }
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

    func loadAll(
        stackUserID: String?,
        teamID: String?
    ) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID).filter {
            isCompatible(instanceTag: $0.instanceTag)
        }
    }

    func activeMac(
        stackUserID: String?,
        teamID: String?
    ) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .first(where: \.isActive)
    }

    func setActive(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter {
                cmxCanonicalDeviceID($0.macDeviceID)
                    == cmxCanonicalDeviceID(macDeviceID)
            }
        guard matches.count == 1, let target = matches.first else { return }
        try await setActive(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
        try await inner.setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter {
                cmxCanonicalDeviceID($0.macDeviceID)
                    == cmxCanonicalDeviceID(macDeviceID)
            }
        guard matches.count == 1, let target = matches.first else { return }
        try await setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
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

    func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
        try await inner.setConnectionMethod(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            rawValue: rawValue,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func remove(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter {
                cmxCanonicalDeviceID($0.macDeviceID)
                    == cmxCanonicalDeviceID(macDeviceID)
            }
        guard matches.count == 1, let target = matches.first else { return }
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: target.instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
        try await inner.remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Forward exact-scope removal down the SAME rail rather than falling back to
    /// the protocol default (which routes to `remove`). The inner build-scope
    /// decorator's `remove` over-deletes its team-less fallback row; its
    /// `removeExactScope` deletes only the exact scope. Keeping the exact-scope
    /// call on the exact-scope path preserves that guarantee.
    ///
    /// NO compatibility guard here, deliberately: an exact-scope delete targets a
    /// row the caller explicitly captured from `loadAllInstances` (which forwards
    /// incompatible rows so a forget's cleanup can match the broker's TAG-BLIND
    /// wildcard revoke). Silently skipping an incompatible tag would let the
    /// backup tombstone flush and the forget report success while the local row
    /// — whose binding is already revoked — survives to resurface as a dead
    /// entry. The guard remains on the ambient verbs (`upsert`, `remove`,
    /// `setCustomization`), which act on live rows this build may not touch.
    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await inner.removeExactScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Forward the cross-team enumeration down the rail unchanged. This is a
    /// read used to target deletions during a forget: rows with incompatible
    /// tags are included on purpose, because the broker's wildcard revoke is
    /// tag-blind and the cleanup's exact-scope deletes must match its breadth.
    func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID
        )
    }

    /// Forward the sign-out wipe down the rail TAG-BLIND, like
    /// `removeExactScope`. Enumerating this store's own compatibility-filtered
    /// view would strand rows a since-revoked allowlist grant persisted: they
    /// are invisible to this build until re-granted, and a sign-out that
    /// reports success while another account's pairings survive on disk is a
    /// broken wipe.
    func removeAll() async throws {
        try await inner.removeAll()
    }

    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {
        guard isCompatible(instanceTag: instanceTag) else { return }
        try await inner.authorizeUserTailscaleRoutes(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            routes: routes
        )
    }

    /// Legacy rows remain visible long enough to be claimed by an
    /// authenticated tagged instance. Live route adoption still fails closed
    /// in ``MobileMacBuildCompatibilityPolicy/allows(instanceTag:)``.
    private func isCompatible(instanceTag: String?) -> Bool {
        instanceTag == nil || policy.allows(instanceTag: instanceTag)
    }
}
