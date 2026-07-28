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
        guard let target = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .first(where: { $0.macDeviceID == macDeviceID }) else { return }
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
        guard let target = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .first(where: { $0.macDeviceID == macDeviceID }) else { return }
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

    func remove(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard let target = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .first(where: { $0.macDeviceID == macDeviceID }) else { return }
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

    func removeAll() async throws {
        for mac in try await loadAll(stackUserID: nil, teamID: nil) {
            try await inner.remove(
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag,
                stackUserID: mac.stackUserID,
                teamID: mac.teamID
            )
        }
    }

    /// Legacy rows remain visible long enough to be claimed by an
    /// authenticated tagged instance. Live route adoption still fails closed
    /// in ``MobileMacBuildCompatibilityPolicy/allows(instanceTag:)``.
    private func isCompatible(instanceTag: String?) -> Bool {
        instanceTag == nil || policy.allows(instanceTag: instanceTag)
    }
}
