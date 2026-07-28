import Testing
@testable import CmuxMobileShellModel

struct MachineAvatarPaletteTests {
    @Test func sameMachineSharesSlotRegardlessOfWorkspace() {
        let palette = MachineAvatarPalette()
        let a = palette.slot(machineID: "mac-studio-abc", fallbackID: "ws-1")
        let b = palette.slot(machineID: "mac-studio-abc", fallbackID: "ws-2")
        #expect(a == b)
    }

    @Test func nilOrEmptyMachineFallsBackToWorkspaceID() {
        let palette = MachineAvatarPalette()
        let viaNil = palette.slot(machineID: nil, fallbackID: "ws-42")
        let viaEmpty = palette.slot(machineID: "", fallbackID: "ws-42")
        let direct = palette.slot(machineID: "ws-42", fallbackID: "ignored")
        // Unknown machine keys off the workspace id, so all three agree.
        #expect(viaNil == viaEmpty)
        #expect(viaNil == direct)
    }

    @Test func slotIsAlwaysInRange() {
        let palette = MachineAvatarPalette(slotCount: 8)
        for id in ["", "a", "mac-mini-1", "100.64.0.7", "AAAA", "ZZZZ", "🙂x"] {
            let slot = palette.slot(machineID: id, fallbackID: "fb")
            #expect(slot >= 0 && slot < 8)
        }
    }

    @Test func distinctMachinesSpreadAcrossSlots() {
        // djb2 should not pile a handful of realistic machine ids onto one slot.
        let ids = ["cmux-lawrence", "cmux-macmini", "cmux-studio", "macbook-pro", "mac-mini-2"]
        let palette = MachineAvatarPalette()
        let slots = Set(ids.map { palette.slot(machineID: $0, fallbackID: "fb") })
        #expect(slots.count >= 3)
    }
}
