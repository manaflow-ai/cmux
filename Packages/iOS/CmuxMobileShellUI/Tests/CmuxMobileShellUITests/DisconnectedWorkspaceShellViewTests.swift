#if os(iOS)
@testable import CmuxMobileShell
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite
struct DisconnectedWorkspaceShellViewTests {
    @Test func successfulEmptyLoadAutoPresentsAddDeviceWithoutHiddenSuppression() {
        let store = MobileShellComposite()
        store.pairedMacLoadState = .loaded
        store.hasHiddenComputers = true

        let view = DisconnectedWorkspaceShellView(
            hasKnownPairedMac: false,
            showAddDevice: {},
            showPairingScanner: {},
            signOut: {},
            store: store
        )

        #expect(view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }

    @Test func incompleteEmptyLoadDoesNotAutoPresentAddDevice() {
        let store = MobileShellComposite()
        let view = DisconnectedWorkspaceShellView(
            hasKnownPairedMac: false,
            showAddDevice: {},
            showPairingScanner: {},
            signOut: {},
            store: store
        )

        #expect(!view.shouldAutoPresentAddDeviceAfterLoadingSavedMacs)
    }
}
#endif
