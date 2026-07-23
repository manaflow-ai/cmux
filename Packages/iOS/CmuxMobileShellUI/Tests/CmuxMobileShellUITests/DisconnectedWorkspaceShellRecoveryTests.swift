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
        let store = try await shellStore(personalIrohDiscovery: EmptyAccountIrohDiscovery())
        store.hasRecoverableDeletedComputers = true

        let view = disconnectedView(store: store)

        #expect(store.accountComputerRecoveryMode == .recoverDeletedComputer)
        #expect(view.showsAccountComputerRecoveryAction)
    }

    @Test func recoverableDeletedComputerSuppressesAutomaticAddComputerSheet() async throws {
        let store = try await shellStore(personalIrohDiscovery: EmptyAccountIrohDiscovery())
        await store.loadPairedMacs()
        store.hasRecoverableDeletedComputers = true

        let view = disconnectedView(store: store)

        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func emptyDisconnectedStateOffersAccountRecoveryWithoutDeletionMarker() async throws {
        let store = try await shellStore(personalIrohDiscovery: EmptyAccountIrohDiscovery())
        await store.loadPairedMacs()

        let view = disconnectedView(store: store)

        #expect(!store.hasRecoverableDeletedComputers)
        #expect(store.accountComputerRecoveryMode == .findAccountComputer)
        #expect(view.showsAccountComputerRecoveryAction)
        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func emptyStateAutoPresentsAddComputerWhenAccountDiscoveryIsUnavailable() async throws {
        let store = try await shellStore()
        var view = disconnectedView(store: store)
        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)

        await store.loadPairedMacs()
        view = disconnectedView(store: store)

        #expect(view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func failedPairedMacLoadStillOffersAccountRecovery() async throws {
        let store = try await shellStore(
            pairedMacStore: FailingLoadPairedMacStore(),
            personalIrohDiscovery: EmptyAccountIrohDiscovery()
        )
        store.hasRecoverableDeletedComputers = true

        await store.loadPairedMacs()
        let view = disconnectedView(store: store)

        #expect(store.pairedMacLoadState == .failed)
        #expect(store.accountComputerRecoveryMode == .findAccountComputer)
        #expect(view.showsAccountComputerRecoveryAction)
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
        pairedMacStore: any MobilePairedMacStoring = WorkspaceMacSelectionPairedMacStore([]),
        personalIrohDiscovery: (any MobileIrohMacDiscovering)? = nil
    ) async throws -> CMUXMobileShellStore {
        let suiteName = "DisconnectedWorkspaceShellRecoveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            personalIrohDiscovery: personalIrohDiscovery,
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
    }
}

@MainActor
private final class EmptyAccountIrohDiscovery: MobileIrohMacDiscovering {
    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac] { [] }
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
