import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

@Suite("Cloud display names")
struct CloudVMDisplayNamesTests {
    private let machine = SurfaceMachineID.cloud("names-vm")

    private func row(machineID: String, names: [String: Any]) -> [String: Any] {
        [
            "id": "projection_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "frontend_id": CloudVMDisplayMembership.projectionFrontendID,
            "window_id": CloudVMDisplayMembership.namesProjectionWindowID(machine: SurfaceMachineID(rawValue: machineID)),
            "generation": CloudVMDisplayMembership.projectionGeneration,
            "projection_revision": "1",
            "projection": [
                "schema": CloudVMDisplayMembership.namesProjectionSchema,
                "machine_id": machineID,
                "names": names,
            ],
        ]
    }

    private func state(rows: [[String: Any]]) throws -> CloudVMState {
        let snapshot: [String: Any] = [
            "cursor": ["generation": "names", "revision": "1"],
            "workspaces": [["id": "ws_names", "name": "Names", "index": 0, "focused": true]],
            "screens": [], "panes": [], "tabs": [], "terminals": [], "browsers": [], "agents": [],
            "frontend_projections": rows,
        ]
        return try #require(CmuxTuiSnapshotParser.state(fromSnapshot: snapshot, machine: machine))
    }

    @Test("A named display reads back by display id; blanks and non-displays are ignored")
    func namesParse() throws {
        let state = try state(rows: [row(machineID: machine.rawValue, names: [
            "display:2": "  Build box  ", "display:3": "   ", "terminal:1": "nope",
        ])])
        #expect(state.displayNames == ["display:2": "Build box"])
    }

    @Test("Another machine's names never apply")
    func foreignMachineIgnored() throws {
        let state = try state(rows: [row(machineID: "vm-other", names: ["display:2": "Theirs"])])
        #expect(state.displayNames.isEmpty)
    }
}

@Suite("Display titles before discovery")
struct CloudDisplayTitleBeforeDiscoveryTests {
    @Test("The desktop placeholder is titled like a discovered display, not Desktop")
    func placeholderIsNumbered() {
        let resource = CmuxTuiSnapshotParser.display(machine: .cloud("title-vm"))
        #expect(resource.title == "Display 1")
        #expect(CmuxTuiSnapshotParser.displayTitle(key: "display:7") == "Display 7")
        #expect(CmuxTuiSnapshotParser.displayTitle(key: "screen-1") == "Desktop")
    }
}
