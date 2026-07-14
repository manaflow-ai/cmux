import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
@testable import CmuxMobileShell

struct ReconnectPersistenceProbeStore: MobilePairedMacStoring {
    private enum ProbeError: Error {
        case loadFailed
    }

    private actor State {
        private let failFirstLoadAfterWrite: Bool
        private var hasWritten = false
        private var didFailLoad = false

        init(failFirstLoadAfterWrite: Bool) {
            self.failFirstLoadAfterWrite = failFirstLoadAfterWrite
        }

        func recordWrite() {
            hasWritten = true
        }

        func shouldFailLoad() -> Bool {
            guard failFirstLoadAfterWrite, hasWritten, !didFailLoad else { return false }
            didFailLoad = true
            return true
        }
    }

    let inner: any MobilePairedMacStoring
    let invalidateAfterWrite: SynchronousGenerationBoundary?
    private let state: State

    init(
        inner: any MobilePairedMacStoring,
        invalidateAfterWrite: SynchronousGenerationBoundary? = nil,
        failFirstLoadAfterWrite: Bool = false
    ) {
        self.inner = inner
        self.invalidateAfterWrite = invalidateAfterWrite
        self.state = State(failFirstLoadAfterWrite: failFirstLoadAfterWrite)
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
        await didWrite()
    }

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
        let wrote = try await inner.upsertIfNewer(
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
        if wrote { await didWrite() }
        return wrote
    }

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
        let wrote = try await inner.upsertRoutesIfAuthorized(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            condition: condition,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        if wrote { await didWrite() }
        return wrote
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        if await state.shouldFailLoad() {
            throw ProbeError.loadFailed
        }
        return try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(
            macDeviceID: macDeviceID,
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

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func rollbackRejectedUpsert(
        _ rollback: MobilePairedMacUpsertRollback
    ) async throws {
        try await inner.rollbackRejectedUpsert(rollback)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }

    private func didWrite() async {
        await state.recordWrite()
        invalidateAfterWrite?.invalidate()
    }
}
