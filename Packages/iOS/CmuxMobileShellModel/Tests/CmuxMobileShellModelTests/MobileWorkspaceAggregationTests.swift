import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceAggregationTests {
    private func ws(_ id: String, mac: String, name: String? = nil) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            macDeviceID: mac,
            name: name ?? id,
            terminals: []
        )
    }

    private func state(_ mac: String, name: String?, _ ids: [String]) -> MacWorkspaceState {
        MacWorkspaceState(
            macDeviceID: mac,
            displayName: name,
            workspaces: ids.map { ws($0, mac: mac) },
            status: .connected
        )
    }

    private func machineColorIndex(
        statesByMac states: [String: MacWorkspaceState],
        existingAssignments: [String: Int] = [:]
    ) -> [String: Int] {
        MobileWorkspaceAggregation().machineColorIndex(
            existingAssignments: existingAssignments,
            adding: Array(states.keys)
        )
    }

    private func derivedWorkspaces(
        statesByMac states: [String: MacWorkspaceState],
        foregroundMacDeviceID: String?
    ) -> [MobileWorkspacePreview] {
        let aggregation = MobileWorkspaceAggregation()
        return aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: foregroundMacDeviceID,
            machineColorIndex: aggregation.machineColorIndex(
                existingAssignments: [:],
                adding: Array(states.keys)
            )
        )
    }

    @Test func distinctMacsGetDistinctColorIndicesAndSameMacShares() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1", "a2"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let idx = machineColorIndex(statesByMac: states)
        // Different Macs must never collide on one color (the "both yellow" bug).
        #expect(idx["mac-a"] != idx["mac-b"])
        let derived = MobileWorkspaceAggregation().derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            machineColorIndex: idx
        )
        // Same Mac's workspaces all carry that Mac's single color index.
        #expect(derived.filter { $0.macDeviceID == "mac-a" }.allSatisfy { $0.machineColorIndex == idx["mac-a"] })
        #expect(derived.first { $0.macDeviceID == "mac-b" }?.machineColorIndex == idx["mac-b"])
        #expect(derived.filter { $0.macDeviceID == "mac-a" }.allSatisfy { $0.macDisplayName == "Alpha" })
        #expect(derived.first { $0.macDeviceID == "mac-b" }?.macDisplayName == "Beta")
    }

    @Test func colorIndexStaysStableWhenLiveMacSetCollapsesDuringSwitch() {
        let aggregation = MobileWorkspaceAggregation()
        let settledStates = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        var settledIndex = aggregation.machineColorIndex(
            existingAssignments: [:],
            adding: Array(settledStates.keys)
        )
        let macAIndex = settledIndex["mac-a"]
        let macBIndex = settledIndex["mac-b"]

        let collapsedToSwitchedMac = [
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        settledIndex = aggregation.machineColorIndex(
            existingAssignments: settledIndex,
            adding: Array(collapsedToSwitchedMac.keys)
        )
        #expect(settledIndex["mac-b"] == macBIndex)

        settledIndex = aggregation.machineColorIndex(
            existingAssignments: settledIndex,
            adding: Array(settledStates.keys)
        )
        #expect(settledIndex["mac-a"] == macAIndex)
        #expect(settledIndex["mac-b"] == macBIndex)

        var withTransientThirdMac = settledStates
        withTransientThirdMac["mac-c"] = state("mac-c", name: "Gamma", ["c1"])
        settledIndex = aggregation.machineColorIndex(
            existingAssignments: settledIndex,
            adding: Array(withTransientThirdMac.keys)
        )
        #expect(settledIndex["mac-a"] == macAIndex)
        #expect(settledIndex["mac-b"] == macBIndex)
    }

    @Test func colorIndexIgnoresEmptyMacKeys() {
        let states = [
            "": state("", name: nil, ["x"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
        ]
        let idx = machineColorIndex(statesByMac: states)
        #expect(idx[""] == nil)
        #expect(idx["mac-a"] != nil)
    }

    @Test func foregroundWorkspacesComeFirst() {
        let states = [
            "mac-b": state("mac-b", name: "Beta", ["b1", "b2"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
        ]
        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-b")
        // Foreground (mac-b) first regardless of name order, then the rest.
        #expect(derived.map(\.rpcWorkspaceID.rawValue) == ["b1", "b2", "a1"])
    }

    @Test func nonForegroundMacsOrderedByDisplayNameThenID() {
        let states = [
            "mac-z": state("mac-z", name: "Charlie", ["z1"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-m": state("mac-m", name: "Bravo", ["m1"]),
        ]
        // No foreground: pure name order Alpha, Bravo, Charlie.
        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: nil)
        #expect(derived.map(\.rpcWorkspaceID.rawValue) == ["a1", "m1", "z1"])
    }

    @Test func keepsSameWorkspaceIDFromDifferentMacsDistinct() {
        // Workspace ids are Mac-local, so the same raw id on two Macs must render
        // as two navigable rows while RPC still sends the Mac-local id.
        let states = [
            "mac-fg": MacWorkspaceState(macDeviceID: "mac-fg", displayName: "FG", workspaces: [ws("shared", mac: "mac-fg", name: "from-fg")], status: .connected),
            "mac-bg": MacWorkspaceState(macDeviceID: "mac-bg", displayName: "BG", workspaces: [ws("shared", mac: "mac-bg", name: "from-bg")], status: .connected),
        ]
        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(derived.map(\.name) == ["from-fg", "from-bg"])
        #expect(Set(derived.map(\.id)).count == 2)
        #expect(derived.map(\.rpcWorkspaceID.rawValue) == ["shared", "shared"])
        #expect(derived.map(\.macDeviceID) == ["mac-fg", "mac-bg"])
    }

    @Test func rowStatusComesFromOwningMac() {
        let states = [
            "mac-fg": MacWorkspaceState(macDeviceID: "mac-fg", displayName: "FG", workspaces: [ws("w1", mac: "mac-fg")], status: .connected),
            "mac-bg": MacWorkspaceState(macDeviceID: "mac-bg", displayName: "BG", workspaces: [ws("w2", mac: "mac-bg")], status: .unavailable),
        ]
        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(derived.first { $0.rpcWorkspaceID.rawValue == "w1" }?.macConnectionStatus == .connected)
        #expect(derived.first { $0.rpcWorkspaceID.rawValue == "w2" }?.macConnectionStatus == .unavailable)
    }

    @Test func rowActionCapabilitiesComeFromOwningMac() {
        let foregroundCapabilities = MobileWorkspaceActionCapabilities(supportsWorkspaceActions: true)
        let backgroundCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsReadStateActions: true,
            supportsCloseActions: true
        )
        let states = [
            "mac-fg": MacWorkspaceState(
                macDeviceID: "mac-fg",
                displayName: "FG",
                workspaces: [ws("w1", mac: "mac-fg")],
                status: .connected,
                actionCapabilities: foregroundCapabilities
            ),
            "mac-bg": MacWorkspaceState(
                macDeviceID: "mac-bg",
                displayName: "BG",
                workspaces: [ws("w2", mac: "mac-bg")],
                status: .connected,
                actionCapabilities: backgroundCapabilities
            ),
        ]

        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")

        #expect(derived.first { $0.rpcWorkspaceID.rawValue == "w1" }?.actionCapabilities == foregroundCapabilities)
        #expect(derived.first { $0.rpcWorkspaceID.rawValue == "w2" }?.actionCapabilities == backgroundCapabilities)
    }

    @Test func emptyStateMapDerivesEmptyList() {
        #expect(derivedWorkspaces(statesByMac: [:], foregroundMacDeviceID: "mac-a").isEmpty)
    }

    @Test func updatingOneMacReflectsImmediatelyInDerivation() {
        // The core "derived all the way through" guarantee: mutate one Mac's
        // state and the derived list reflects it with no explicit publish.
        var states = [
            "mac-fg": state("mac-fg", name: "FG", ["w1"]),
            "mac-bg": state("mac-bg", name: "BG", ["w2"]),
        ]
        #expect(derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg").count == 2)
        // A workspace is created on the background Mac.
        states["mac-bg"]?.workspaces.append(ws("w3", mac: "mac-bg"))
        let derived = derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(derived.map(\.rpcWorkspaceID.rawValue) == ["w1", "w2", "w3"])
    }

    private func group(_ id: String, anchor: String) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(id: .init(rawValue: id), name: id, anchorWorkspaceID: .init(rawValue: anchor))
    }

    @Test func groupsFromEveryMacStayDistinctInAggregatedList() throws {
        var foregroundAnchor = ws("foreground-anchor", mac: "mac-fg")
        foregroundAnchor.groupID = "shared-group"
        var backgroundAnchor = ws("background-anchor", mac: "mac-bg")
        backgroundAnchor.groupID = "shared-group"
        let states = [
            "mac-fg": MacWorkspaceState(
                macDeviceID: "mac-fg",
                displayName: "FG",
                workspaces: [foregroundAnchor],
                groups: [MobileWorkspaceGroupPreview(
                    id: "shared-group",
                    name: "Foreground Group",
                    anchorWorkspaceID: foregroundAnchor.id
                )],
                status: .connected
            ),
            "mac-bg": MacWorkspaceState(
                macDeviceID: "mac-bg",
                displayName: "BG",
                workspaces: [backgroundAnchor],
                groups: [MobileWorkspaceGroupPreview(
                    id: "shared-group",
                    name: "Background Group",
                    anchorWorkspaceID: backgroundAnchor.id
                )],
                status: .connected
            ),
        ]
        let aggregation = MobileWorkspaceAggregation()
        let workspaces = aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: "mac-fg",
            machineColorIndex: machineColorIndex(statesByMac: states)
        )
        let groups = aggregation.derivedGroups(
            statesByMac: states,
            foregroundMacDeviceID: "mac-fg"
        )
        let items = MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
        let headerNames = items.compactMap { item -> String? in
            guard case .groupHeader(let group, _) = item else { return nil }
            return group.name
        }
        let shownForeground = try #require(
            workspaces.first { $0.name == "foreground-anchor" }
        )
        let shownBackground = try #require(
            workspaces.first { $0.name == "background-anchor" }
        )

        #expect(headerNames == ["Foreground Group", "Background Group"])
        #expect(Set(groups.map(\.id)).count == 2)
        let shownForegroundGroup = try #require(
            groups.first { $0.name == "Foreground Group" }
        )
        let shownBackgroundGroup = try #require(
            groups.first { $0.name == "Background Group" }
        )
        #expect(shownForeground.groupID == shownForegroundGroup.id)
        #expect(shownBackground.groupID == shownBackgroundGroup.id)
    }

    @Test func foregroundGroupAnchorsFollowScopedWorkspaceRowIDs() {
        let aggregation = MobileWorkspaceAggregation()
        var foregroundWorkspace = ws("local-w1", mac: "mac-fg")
        foregroundWorkspace.remoteWorkspaceID = .init(rawValue: "remote-w1")
        let states = [
            "mac-fg": MacWorkspaceState(
                macDeviceID: "mac-fg",
                displayName: "FG",
                workspaces: [foregroundWorkspace],
                groups: [group("g1", anchor: "local-w1")],
                status: .connected
            ),
            "mac-bg": state("mac-bg", name: "BG", ["w2"]),
        ]

        let workspaces = aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: "mac-fg",
            machineColorIndex: aggregation.machineColorIndex(
                existingAssignments: [:],
                adding: Array(states.keys)
            )
        )
        let groups = aggregation.derivedGroups(statesByMac: states, foregroundMacDeviceID: "mac-fg")

        #expect(groups.first?.anchorWorkspaceID == workspaces.first?.id)
        #expect(groups.first?.anchorWorkspaceID.rawValue == "mac-fg\u{1F}remote-w1")
    }

    @Test func precomputedMacOrderDrivesWorkspaceAndGroupDerivations() {
        var macAWorkspace = ws("a1", mac: "mac-a")
        macAWorkspace.groupID = "group-a"
        var macBWorkspace = ws("b1", mac: "mac-b")
        macBWorkspace.groupID = "group-b"
        let states = [
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                displayName: "Alpha",
                workspaces: [macAWorkspace],
                groups: [group("group-a", anchor: "a1")],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                displayName: "Beta",
                workspaces: [macBWorkspace],
                groups: [group("group-b", anchor: "b1")],
                status: .connected
            ),
        ]
        let aggregation = MobileWorkspaceAggregation()
        let macIDsInDisplayOrder = ["mac-b", "mac-a"]

        let workspaces = aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            machineColorIndex: machineColorIndex(statesByMac: states),
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )
        let groups = aggregation.derivedGroups(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )

        #expect(workspaces.map(\.rpcWorkspaceID.rawValue) == ["b1", "a1"])
        #expect(groups.map(\.rpcGroupID.rawValue) == ["group-b", "group-a"])
    }

    @Test func computerPriorityOverridesForegroundAndNameOrder() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
            "mac-c": state("mac-c", name: "Charlie", ["c1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            computerPriority: ["mac-c", "mac-b"]
        )
        // The user's explicit order beats both foreground-first and name order;
        // the unprioritized foreground Mac follows the prioritized ones.
        #expect(ordered == ["mac-c", "mac-b", "mac-a"])
    }

    @Test func unprioritizedMacsKeepAutomaticOrderAfterPrioritizedOnes() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
            "mac-c": state("mac-c", name: "Charlie", ["c1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-c",
            computerPriority: ["mac-b"]
        )
        // mac-b is pinned first; the rest keep foreground-then-name order.
        #expect(ordered == ["mac-b", "mac-c", "mac-a"])
    }

    @Test func computerPriorityIgnoresUnknownAndEmptyEntries() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: nil,
            computerPriority: ["", "gone-mac", "mac-b"]
        )
        #expect(ordered == ["mac-b", "mac-a"])
    }

    @Test func computerPriorityDoesNotRankAnUnlistedSiblingBuild() {
        var nightly = state("mac-a", name: "Alpha", ["a-nightly"])
        nightly.instanceTag = "nightly"
        var stable = state("mac-a", name: "Alpha", ["a-stable"])
        stable.instanceTag = nil
        let states = [
            "mac-a\u{1F}nightly": nightly,
            "mac-a": stable,
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-b",
            computerPriority: ["mac-a"]
        )
        // Stable is pinned. The separately identified Nightly build remains
        // unprioritized, so the unprioritized foreground Mac comes before it.
        #expect(ordered == ["mac-a", "mac-b", "mac-a\u{1F}nightly"])
    }

    @Test func computerPriorityOrdersSiblingBuildsIndependently() {
        var nightly = state("mac-a", name: "Alpha", ["a-nightly"])
        nightly.instanceTag = "nightly"
        var stable = state("mac-a", name: "Alpha", ["a-stable"])
        stable.instanceTag = "stable"
        let states = [
            "mac-a\u{1F}nightly": nightly,
            "mac-a\u{1F}stable": stable,
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-b",
            computerPriority: [
                "mac-a\u{1F}nightly",
                "mac-b",
                "mac-a\u{1F}stable",
            ]
        )

        #expect(ordered == [
            "mac-a\u{1F}nightly",
            "mac-b",
            "mac-a\u{1F}stable",
        ])
    }

    @Test func foregroundOrderUsesCanonicalPairingIdentity() {
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: " nightly ",
            displayName: "Alpha",
            status: .connected
        )
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: [state.id: state],
            foregroundMacDeviceID: "mac-a\u{1F} nightly "
        )

        #expect(ordered == ["mac-a\u{1F}nightly"])
        #expect(state.id == "mac-a\u{1F}nightly")
    }

    @Test func lastOpenedOrdersUnprioritizedMacsByRecencyThenName() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
            "mac-c": state("mac-c", name: "Charlie", ["c1"]),
            "mac-d": state("mac-d", name: "Delta", ["d1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            lastOpenedAt: [
                "mac-a": Date(timeIntervalSince1970: 50),
                "mac-c": Date(timeIntervalSince1970: 300),
                "mac-b": Date(timeIntervalSince1970: 200),
            ]
        )
        // Foreground still leads even with an older stamp (it is open NOW),
        // then most recently opened, then never-opened computers by name.
        #expect(ordered == ["mac-a", "mac-c", "mac-b", "mac-d"])
    }

    @Test func computerPriorityBeatsLastOpenedRecency() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let ordered = MobileWorkspaceAggregation().orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: nil,
            computerPriority: ["mac-a"],
            lastOpenedAt: ["mac-b": Date(timeIntervalSince1970: 500)]
        )
        #expect(ordered == ["mac-a", "mac-b"])
    }

    @Test func emptyComputerPriorityMatchesAutomaticOrder() {
        let states = [
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
        ]
        let aggregation = MobileWorkspaceAggregation()
        let automatic = aggregation.orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-b"
        )
        let withEmptyPriority = aggregation.orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-b",
            computerPriority: []
        )
        #expect(automatic == withEmptyPriority)
    }

    @Test func computerPriorityOrderDrivesWorkspaceAndGroupDerivations() {
        var macAWorkspace = ws("a1", mac: "mac-a")
        macAWorkspace.groupID = "group-a"
        var macBWorkspace = ws("b1", mac: "mac-b")
        macBWorkspace.groupID = "group-b"
        let states = [
            "mac-a": MacWorkspaceState(
                macDeviceID: "mac-a",
                displayName: "Alpha",
                workspaces: [macAWorkspace],
                groups: [group("group-a", anchor: "a1")],
                status: .connected
            ),
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                displayName: "Beta",
                workspaces: [macBWorkspace],
                groups: [group("group-b", anchor: "b1")],
                status: .connected
            ),
        ]
        let aggregation = MobileWorkspaceAggregation()
        let macIDsInDisplayOrder = aggregation.orderedMacIDs(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            computerPriority: ["mac-b"]
        )

        let workspaces = aggregation.derivedWorkspaces(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            machineColorIndex: machineColorIndex(statesByMac: states),
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )
        let groups = aggregation.derivedGroups(
            statesByMac: states,
            foregroundMacDeviceID: "mac-a",
            macIDsInDisplayOrder: macIDsInDisplayOrder
        )

        // Workspaces and group sections both follow the prioritized Mac order,
        // so sections never detach from their members.
        #expect(workspaces.map(\.rpcWorkspaceID.rawValue) == ["b1", "a1"])
        #expect(groups.map(\.rpcGroupID.rawValue) == ["group-b", "group-a"])
    }
}
