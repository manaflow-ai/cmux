#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
@testable import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite
struct DisconnectedWorkspaceShellRecoveryTests {
    @Test func emptyDisconnectedStateOffersDeletedComputerRecovery() async throws {
        let store = try await shellStore()
        store.hasRecoverableDeletedComputers = true

        let view = disconnectedView(store: store)

        #expect(view.showsDeletedComputerRecoveryAction)
    }

    @Test func recoverableDeletedComputerSuppressesAutomaticAddComputerSheet() async throws {
        let store = try await shellStore()
        await store.loadPairedMacs()
        store.hasRecoverableDeletedComputers = true

        let view = disconnectedView(store: store)

        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func emptyStateAutoPresentsAddComputerOnlyAfterSuccessfulLoad() async throws {
        let store = try await shellStore()
        var view = disconnectedView(store: store)
        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)

        await store.loadPairedMacs()
        view = disconnectedView(store: store)

        #expect(view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func failedPairedMacLoadDoesNotAutoPresentAddComputer() async throws {
        let store = try await shellStore(pairedMacStore: FailingLoadPairedMacStore())
        store.hasRecoverableDeletedComputers = true

        await store.loadPairedMacs()
        let view = disconnectedView(store: store)

        #expect(store.pairedMacLoadState == .failed)
        #expect(!view.showsDeletedComputerRecoveryAction)
        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    private func disconnectedView(store: CMUXMobileShellStore) -> DisconnectedWorkspaceShellView {
        DisconnectedWorkspaceShellView(
            hasKnownPairedMac: true,
            showAddDevice: {},
            showPairingScanner: {},
            signOut: {},
            store: store
        )
    }

    private func shellStore(
        pairedMacStore: any MobilePairedMacStoring = WorkspaceMacSelectionPairedMacStore([])
    ) async throws -> CMUXMobileShellStore {
        let suiteName = "DisconnectedWorkspaceShellRecoveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
    }
}

private enum FailingLoadPairedMacStoreError: Error {
    case loadFailed
}

private actor FailingLoadPairedMacStore: MobilePairedMacStoring {
    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {}

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
    ) async throws -> Bool { false }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        throw FailingLoadPairedMacStoreError.loadFailed
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? { nil }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}

    func clearActive(stackUserID: String?, teamID: String?) async throws {}

    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {}

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}

    func removeAll() async throws {}
}
#endif
