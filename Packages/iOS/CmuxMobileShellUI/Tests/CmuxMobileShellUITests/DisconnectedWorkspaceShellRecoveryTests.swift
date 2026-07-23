#if os(iOS)
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

    private func disconnectedView(store: CMUXMobileShellStore) -> DisconnectedWorkspaceShellView {
        DisconnectedWorkspaceShellView(
            hasKnownPairedMac: true,
            showAddDevice: {},
            showPairingScanner: {},
            signOut: {},
            store: store
        )
    }

    private func shellStore() async throws -> CMUXMobileShellStore {
        let suiteName = "DisconnectedWorkspaceShellRecoveryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: WorkspaceMacSelectionPairedMacStore([]),
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: WorkspaceMacSelectionIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
    }
}
#endif
