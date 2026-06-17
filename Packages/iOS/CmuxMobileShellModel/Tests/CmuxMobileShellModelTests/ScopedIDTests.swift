import Foundation
import Testing
@testable import CmuxMobileShellModel

/// Tests for the multi-Mac scoping value types: bare ids stay Mac-local while
/// the scoped identities (`deviceId` + bare id) disambiguate two Macs that
/// happen to report the same string.
@Suite struct ScopedIDTests {
    @Test func collidingBareWorkspaceIDsResolveIndependently() {
        // Two Macs both report bare workspace id "workspace-1".
        let macA = MobileWorkspacePreview(
            id: "workspace-1",
            deviceId: "mac-A",
            name: "A",
            terminals: []
        )
        let macB = MobileWorkspacePreview(
            id: "workspace-1",
            deviceId: "mac-B",
            name: "B",
            terminals: []
        )

        // The bare ids collide...
        #expect(macA.id == macB.id)
        // ...but the scoped ids are distinct and carry the wire id unchanged.
        let scopedA = ScopedWorkspaceID(macA)
        let scopedB = ScopedWorkspaceID(macB)
        #expect(scopedA != scopedB)
        #expect(scopedA.deviceId == "mac-A")
        #expect(scopedB.deviceId == "mac-B")
        #expect(scopedA.workspaceID == "workspace-1")
        #expect(scopedB.workspaceID == "workspace-1")
        // Usable as dictionary keys without collapsing.
        let routing: [ScopedWorkspaceID: String] = [scopedA: "A", scopedB: "B"]
        #expect(routing[scopedA] == "A")
        #expect(routing[scopedB] == "B")
    }

    @Test func collidingBareTerminalIDsResolveIndependently() {
        let a = MobileTerminalPreview(id: "terminal-1", deviceId: "mac-A", name: "A")
        let b = MobileTerminalPreview(id: "terminal-1", deviceId: "mac-B", name: "B")
        #expect(a.id == b.id)
        let scopedA = ScopedTerminalID(a)
        let scopedB = ScopedTerminalID(b)
        #expect(scopedA != scopedB)
        #expect(scopedA.terminalID == "terminal-1")
        #expect(scopedB.terminalID == "terminal-1")
        let routing: [ScopedTerminalID: String] = [scopedA: "A", scopedB: "B"]
        #expect(routing[scopedA] == "A")
        #expect(routing[scopedB] == "B")
    }

    @Test func scopedIDsRoundTripThroughCodable() throws {
        let scoped = ScopedWorkspaceID(deviceId: "mac-X", workspaceID: "workspace-7")
        let data = try JSONEncoder().encode(scoped)
        let decoded = try JSONDecoder().decode(ScopedWorkspaceID.self, from: data)
        #expect(decoded == scoped)

        let scopedTerminal = ScopedTerminalID(deviceId: "mac-Y", terminalID: "terminal-9")
        let terminalData = try JSONEncoder().encode(scopedTerminal)
        let decodedTerminal = try JSONDecoder().decode(ScopedTerminalID.self, from: terminalData)
        #expect(decodedTerminal == scopedTerminal)
    }

    @Test func deviceIDDefaultsToEmptyForLegacyConstruction() {
        // Construction without deviceId compiles and yields the unscoped case,
        // keeping single-Mac call sites and tests unchanged.
        let workspace = MobileWorkspacePreview(id: "w", name: "W", terminals: [])
        let terminal = MobileTerminalPreview(id: "t", name: "T")
        #expect(workspace.deviceId == "")
        #expect(terminal.deviceId == "")
        #expect(ScopedWorkspaceID(workspace).deviceId == "")
        #expect(ScopedTerminalID(terminal).deviceId == "")
    }
}
