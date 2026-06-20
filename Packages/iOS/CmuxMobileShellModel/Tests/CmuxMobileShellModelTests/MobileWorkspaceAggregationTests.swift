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

    @Test func distinctMacsGetDistinctColorIndicesAndSameMacShares() {
        let states = [
            "mac-a": state("mac-a", name: "Alpha", ["a1", "a2"]),
            "mac-b": state("mac-b", name: "Beta", ["b1"]),
        ]
        let idx = MobileWorkspaceAggregation.machineColorIndex(statesByMac: states)
        // Different Macs must never collide on one color (the "both yellow" bug).
        #expect(idx["mac-a"] != idx["mac-b"])
        let derived = MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-a")
        // Same Mac's workspaces all carry that Mac's single color index.
        #expect(derived.filter { $0.macDeviceID == "mac-a" }.allSatisfy { $0.machineColorIndex == idx["mac-a"] })
        #expect(derived.first { $0.macDeviceID == "mac-b" }?.machineColorIndex == idx["mac-b"])
    }

    @Test func colorIndexIgnoresEmptyMacKeys() {
        let states = [
            "": state("", name: nil, ["x"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
        ]
        let idx = MobileWorkspaceAggregation.machineColorIndex(statesByMac: states)
        #expect(idx[""] == nil)
        #expect(idx["mac-a"] != nil)
    }

    @Test func foregroundWorkspacesComeFirst() {
        let states = [
            "mac-b": state("mac-b", name: "Beta", ["b1", "b2"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
        ]
        let derived = MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-b")
        // Foreground (mac-b) first regardless of name order, then the rest.
        #expect(derived.map(\.id.rawValue) == ["b1", "b2", "a1"])
    }

    @Test func nonForegroundMacsOrderedByDisplayNameThenID() {
        let states = [
            "mac-z": state("mac-z", name: "Charlie", ["z1"]),
            "mac-a": state("mac-a", name: "Alpha", ["a1"]),
            "mac-m": state("mac-m", name: "Bravo", ["m1"]),
        ]
        // No foreground: pure name order Alpha, Bravo, Charlie.
        let derived = MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: nil)
        #expect(derived.map(\.id.rawValue) == ["a1", "m1", "z1"])
    }

    @Test func deduplicatesByWorkspaceIDForegroundWins() {
        // The same workspace id appears on two Macs; the foreground copy wins and
        // the duplicate is dropped (one row, not two).
        let states = [
            "mac-fg": MacWorkspaceState(macDeviceID: "mac-fg", displayName: "FG", workspaces: [ws("shared", mac: "mac-fg", name: "from-fg")], status: .connected),
            "mac-bg": MacWorkspaceState(macDeviceID: "mac-bg", displayName: "BG", workspaces: [ws("shared", mac: "mac-bg", name: "from-bg")], status: .connected),
        ]
        let derived = MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(derived.map(\.id.rawValue) == ["shared"])
        #expect(derived.first?.macDeviceID == "mac-fg") // foreground copy kept
    }

    @Test func emptyStateMapDerivesEmptyList() {
        #expect(MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: [:], foregroundMacDeviceID: "mac-a").isEmpty)
    }

    @Test func updatingOneMacReflectsImmediatelyInDerivation() {
        // The core "derived all the way through" guarantee: mutate one Mac's
        // state and the derived list reflects it with no explicit publish.
        var states = [
            "mac-fg": state("mac-fg", name: "FG", ["w1"]),
            "mac-bg": state("mac-bg", name: "BG", ["w2"]),
        ]
        #expect(MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg").count == 2)
        // A workspace is created on the background Mac.
        states["mac-bg"]?.workspaces.append(ws("w3", mac: "mac-bg"))
        let derived = MobileWorkspaceAggregation.derivedWorkspaces(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(derived.map(\.id.rawValue) == ["w1", "w2", "w3"])
    }

    private func group(_ id: String, anchor: String) -> MobileWorkspaceGroupPreview {
        MobileWorkspaceGroupPreview(id: .init(rawValue: id), name: id, anchorWorkspaceID: .init(rawValue: anchor))
    }

    @Test func groupsComeFromForegroundMac() {
        let states = [
            "mac-fg": MacWorkspaceState(macDeviceID: "mac-fg", displayName: "FG", workspaces: [], groups: [group("g1", anchor: "w1")], status: .connected),
            "mac-bg": MacWorkspaceState(macDeviceID: "mac-bg", displayName: "BG", workspaces: [], groups: [group("g2", anchor: "w2")], status: .connected),
        ]
        let groups = MobileWorkspaceAggregation.derivedGroups(statesByMac: states, foregroundMacDeviceID: "mac-fg")
        #expect(groups.map { $0.id.rawValue } == ["g1"])
    }
}
