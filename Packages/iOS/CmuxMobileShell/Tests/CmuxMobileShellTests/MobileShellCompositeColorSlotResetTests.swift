import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression tests for `stableMacColorSlots` resets on the account/team
/// boundaries. Split from ``MobileShellCompositePreviewTests`` to keep that
/// file under the Swift file length budget.
@MainActor
@Suite struct MobileShellCompositeColorSlotResetTests {
    @Test func signOutClearsStableMacColorSlots() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        // Seed a real (non-anonymous) Mac's color slot so sign-out has something
        // to leak: without an explicit reset, `stableMacColorSlots` is
        // additive-only, so the next account's slots would start numbering past
        // this account's stale entry instead of at zero.
        store.workspacesByMac["mac-previous-account"] = MacWorkspaceState(
            macDeviceID: "mac-previous-account",
            workspaces: []
        )
        #expect(store.machineColorIndex["mac-previous-account"] != nil)

        store.signOut()

        // The previous account's Mac→color assignment must not survive
        // sign-out into the next account's session.
        #expect(store.machineColorIndex.isEmpty)
    }

    @Test func teamSwitchDropsBackgroundMacColorSlotsButKeepsForeground() {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        // A real (non-anonymous) foreground Mac, plus a background Mac that
        // belongs to the team being switched away from.
        store.foregroundMacDeviceID = "mac-foreground"
        store.workspacesByMac["mac-foreground"] = MacWorkspaceState(
            macDeviceID: "mac-foreground",
            workspaces: []
        )
        store.workspacesByMac["mac-old-team"] = MacWorkspaceState(
            macDeviceID: "mac-old-team",
            workspaces: []
        )
        let foregroundIndexBefore = store.machineColorIndex["mac-foreground"]
        #expect(foregroundIndexBefore != nil)
        #expect(store.machineColorIndex["mac-old-team"] != nil)

        store.currentTeamDidChange()

        // The old team's background Mac must not survive the team switch
        // (additive-only slots would otherwise leak it into the new team's
        // numbering forever), while the foreground Mac's own slot is left
        // intact so its color doesn't flash/change across the switch.
        #expect(store.machineColorIndex["mac-old-team"] == nil)
        #expect(store.machineColorIndex["mac-foreground"] == foregroundIndexBefore)
    }
}
