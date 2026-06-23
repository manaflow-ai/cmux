import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListFilterTests {
    private func workspace(_ id: String, hasUnread: Bool, mac: String? = nil) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: mac,
            name: "ws",
            hasUnread: hasUnread,
            terminals: []
        )
    }

    @Test func allMatchesEverything() {
        let all = MobileWorkspaceListFilter.all
        #expect(all.matches(workspace("a", hasUnread: false, mac: "mac-1")))
        #expect(all.matches(workspace("b", hasUnread: true, mac: "mac-2")))
        #expect(!all.isActive)
    }

    @Test func unreadDimensionMatchesOnlyUnread() {
        let unread = MobileWorkspaceListFilter(readState: .unread)
        #expect(unread.matches(workspace("a", hasUnread: true)))
        #expect(!unread.matches(workspace("b", hasUnread: false)))
        #expect(unread.isActive)
    }

    @Test func machineDimensionMatchesOnlySelectedMacs() {
        let onMac1 = MobileWorkspaceListFilter(machines: ["mac-1"])
        #expect(onMac1.matches(workspace("a", hasUnread: false, mac: "mac-1")))
        #expect(!onMac1.matches(workspace("b", hasUnread: true, mac: "mac-2")))
        // A workspace with no known machine is excluded while a machine filter is active.
        #expect(!onMac1.matches(workspace("c", hasUnread: true, mac: nil)))
        #expect(onMac1.isActive)
    }

    @Test func dimensionsComposeUnreadOnSpecificMac() {
        // "unread on mac-1 and mac-2" — the exact compound case Lawrence asked for.
        let filter = MobileWorkspaceListFilter(readState: .unread, machines: ["mac-1", "mac-2"])
        let rows = [
            workspace("a", hasUnread: true, mac: "mac-1"),   // keep
            workspace("b", hasUnread: false, mac: "mac-1"),  // drop (read)
            workspace("c", hasUnread: true, mac: "mac-3"),   // drop (other mac)
            workspace("d", hasUnread: true, mac: "mac-2"),   // keep
        ]
        #expect(rows.filter(filter.matches).map(\.id.rawValue) == ["a", "d"])
    }

    @Test func emptyMachineSetMeansAllMachines() {
        let unreadAnyMac = MobileWorkspaceListFilter(readState: .unread, machines: [])
        #expect(unreadAnyMac.matches(workspace("a", hasUnread: true, mac: "mac-9")))
        #expect(unreadAnyMac.matches(workspace("b", hasUnread: true, mac: nil)))
    }

    @Test func machineIDsAreDistinctInFirstAppearanceOrder() {
        let rows = [
            workspace("a", hasUnread: false, mac: "mac-2"),
            workspace("b", hasUnread: false, mac: "mac-1"),
            workspace("c", hasUnread: false, mac: "mac-2"), // dup
            workspace("d", hasUnread: false, mac: nil),      // skipped
        ]
        #expect(MobileWorkspaceListFilter.machineIDs(in: rows) == ["mac-2", "mac-1"])
    }

    @Test func pruneMachinesDropsAbsentSelections() {
        var filter = MobileWorkspaceListFilter(readState: .unread, machines: ["mac-1", "mac-gone"])
        let changed = filter.pruneMachines(notIn: ["mac-1", "mac-2"])
        #expect(changed)
        #expect(filter.machines == ["mac-1"])
        // Idempotent when nothing to prune.
        let secondChange = filter.pruneMachines(notIn: ["mac-1", "mac-2"])
        #expect(!secondChange)
    }

    @Test func toggleMachineAddsThenRemoves() {
        var filter = MobileWorkspaceListFilter.all
        filter.toggleMachine("mac-1")
        #expect(filter.machines == ["mac-1"])
        #expect(filter.isActive)
        filter.toggleMachine("mac-1")
        #expect(filter.machines.isEmpty)
        #expect(!filter.isActive)
    }
}
