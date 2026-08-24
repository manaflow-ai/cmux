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

    @Test func machineIDsIncludeTheOwningBuild() {
        var nightly = workspace("nightly", hasUnread: false, mac: "mac-a")
        nightly.macInstanceTag = "nightly"
        var stable = workspace("stable", hasUnread: false, mac: "mac-a")
        stable.macInstanceTag = "stable"

        #expect(MobileWorkspaceListFilter.machineIDs(in: [nightly, stable]) == [
            "mac-a\u{1F}nightly",
            "mac-a\u{1F}stable",
        ])
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

@Suite struct MobileWorkspaceListFilterPairingTests {
    @Test func pairingEntryMatchesExactlyItsOwnBuild() {
        let pairing = "mac-a\u{1F}nightly"
        #expect(MobileWorkspaceListFilter.machineEntryMatches(
            pairing, deviceID: "mac-a", rowTag: "nightly"))
        // Unknown-tag rows never enter an exact build scope: acting on them
        // could route to a sibling. They stay under device entries only.
        #expect(!MobileWorkspaceListFilter.machineEntryMatches(
            pairing, deviceID: "mac-a", rowTag: nil))
        #expect(!MobileWorkspaceListFilter.machineEntryMatches(
            pairing, deviceID: "mac-a", rowTag: "default"))
        #expect(!MobileWorkspaceListFilter.machineEntryMatches(
            pairing, deviceID: "mac-b", rowTag: "nightly"))
    }

    @Test func deviceEntryMatchesOnlyLegacyUntaggedRows() {
        #expect(!MobileWorkspaceListFilter.machineEntryMatches(
            "mac-a", deviceID: "mac-a", rowTag: "nightly"))
        #expect(MobileWorkspaceListFilter.machineEntryMatches(
            "mac-a", deviceID: "mac-a", rowTag: nil))
        #expect(!MobileWorkspaceListFilter.machineEntryMatches(
            "mac-a", deviceID: "mac-b", rowTag: nil))
    }

    @Test func siblingNotificationIdentitiesStayDistinct() {
        let nightly = MobileNotificationFeedItemID(
            macDeviceID: "mac-a", macInstanceTag: "nightly", notificationID: "n-1")
        let stable = MobileNotificationFeedItemID(
            macDeviceID: "mac-a", macInstanceTag: "default", notificationID: "n-1")
        #expect(nightly != stable)
    }

    @Test func siblingStatesDeriveDistinctRowsAndTags() {
        let aggregation = MobileWorkspaceAggregation()
        func preview(_ id: String) -> MobileWorkspacePreview {
            MobileWorkspacePreview(
                id: .init(rawValue: id),
                macDeviceID: "mac-a",
                name: "ws",
                hasUnread: false,
                terminals: []
            )
        }
        let states = [
            "mac-a\u{1F}nightly": MacWorkspaceState(
                macDeviceID: "mac-a",
                instanceTag: "nightly",
                displayName: "Desk Mac",
                workspaces: [preview("ws-1")],
                status: .connected
            ),
            "mac-a\u{1F}default": MacWorkspaceState(
                macDeviceID: "mac-a",
                instanceTag: "default",
                displayName: "Desk Mac",
                workspaces: [preview("ws-1")],
                status: .connected
            ),
        ]
        let derived = aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: nil,
            machineColorIndex: [
                "mac-a\u{1F}nightly": 0,
                "mac-a\u{1F}default": 1,
            ]
        )
        #expect(derived.count == 2)
        #expect(Set(derived.map(\.id)).count == 2)
        #expect(Set(derived.compactMap(\.macInstanceTag)) == ["nightly", "default"])
        #expect(Set(derived.compactMap(\.machineColorIndex)) == [0, 1])
    }

    @Test func identitySpellingNormalizesBuildTagsAcrossFiltersAndRows() {
        var row = MobileWorkspacePreview(
            id: "nightly",
            macDeviceID: "mac-a",
            name: "ws",
            terminals: []
        )
        row.macInstanceTag = " nightly "
        let filter = MobileWorkspaceListFilter(machines: ["mac-a\u{1F} nightly "])

        #expect(filter.matches(row))
        #expect(filter.machines == ["mac-a\u{1F}nightly"])
        #expect(MobileWorkspaceListFilter.machineIDs(in: [row]) == [
            "mac-a\u{1F}nightly",
        ])
    }
}
