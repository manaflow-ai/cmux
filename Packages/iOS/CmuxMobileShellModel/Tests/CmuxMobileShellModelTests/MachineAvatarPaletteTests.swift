import Testing
@testable import CmuxMobileShellModel

struct MachineAvatarPaletteTests {
    @Test func sameMachineSharesSlotRegardlessOfWorkspace() {
        let a = MachineAvatarPalette.slot(machineID: "mac-studio-abc", fallbackID: "ws-1")
        let b = MachineAvatarPalette.slot(machineID: "mac-studio-abc", fallbackID: "ws-2")
        #expect(a == b)
    }

    @Test func nilOrEmptyMachineFallsBackToWorkspaceID() {
        let viaNil = MachineAvatarPalette.slot(machineID: nil, fallbackID: "ws-42")
        let viaEmpty = MachineAvatarPalette.slot(machineID: "", fallbackID: "ws-42")
        let direct = MachineAvatarPalette.slot(machineID: "ws-42", fallbackID: "ignored")
        // Unknown machine keys off the workspace id, so all three agree.
        #expect(viaNil == viaEmpty)
        #expect(viaNil == direct)
    }

    @Test func slotIsAlwaysInRange() {
        for id in ["", "a", "mac-mini-1", "100.64.0.7", "AAAA", "ZZZZ", "🙂x"] {
            let slot = MachineAvatarPalette.slot(machineID: id, fallbackID: "fb", slotCount: 8)
            #expect(slot >= 0 && slot < 8)
        }
    }

    @Test func distinctMachinesSpreadAcrossSlots() {
        // djb2 should not pile a handful of realistic machine ids onto one slot.
        let ids = ["cmux-lawrence", "cmux-macmini", "cmux-studio", "macbook-pro", "mac-mini-2"]
        let slots = Set(ids.map { MachineAvatarPalette.slot(machineID: $0, fallbackID: "fb") })
        #expect(slots.count >= 3)
    }
}
