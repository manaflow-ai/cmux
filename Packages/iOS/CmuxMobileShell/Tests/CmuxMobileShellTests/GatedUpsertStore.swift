import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
@testable import CmuxMobileShell

/// Wraps a real inner store but blocks the first `upsert` until released, so a
/// test can suspend a restore precisely inside its store write and prove the
/// sign-out wipe is final.
actor GatedUpsertStore: MobilePairedMacStoring {
    private let inner: MobilePairedMacStore
    private let failRemove: Bool
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var gateArmed = true

    init(inner: MobilePairedMacStore, failRemove: Bool = false) {
        self.inner = inner
        self.failRemove = failRemove
    }

    func waitUntilUpsertEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func awaitRelease() async {
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func upsert(
        macDeviceID: String, displayName: String?, routes: [CmxAttachRoute],
        instanceTag: String? = nil, markActive: Bool, stackUserID: String?, teamID: String?, now: Date
    ) async throws {
        if gateArmed {
            gateArmed = false
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await awaitRelease()
        }
        try await inner.upsert(
            macDeviceID: macDeviceID, displayName: displayName, routes: routes,
            instanceTag: instanceTag, markActive: markActive,
            stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(
        macDeviceID: String, customName: String?, customColor: String?,
        customIcon: String?, stackUserID: String?, teamID: String?, now: Date
    ) async throws {
        try await inner.setCustomization(
            macDeviceID: macDeviceID, customName: customName, customColor: customColor,
            customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        if failRemove { throw NSError(domain: "GatedUpsertStore", code: 1) }
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}
