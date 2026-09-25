import CmuxMobileCloud
import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileCloudBridge

@Suite("Cloud address")
struct CloudAddressTests {
    @Test("A surface id round-trips its machine and terminal")
    func surfaceRoundTrip() {
        let id = CloudAddress(machineID: "vm-1", component: "term_abc").identifier
        let parsed = CloudAddress(parsing: id)
        #expect(parsed?.machineID == "vm-1")
        #expect(parsed?.component == "term_abc")
    }

    @Test("Identifiers outside the namespace are disowned")
    func foreignIdentifiers() {
        #expect(!CloudAddress.owns("term_abc"))
        #expect(!CloudAddress.owns(""))
        #expect(CloudAddress(parsing: "term_abc") == nil)
        // A Mac surface id that merely starts with the word is not ours.
        #expect(!CloudAddress.owns("cmux-cloudy"))
    }

    @Test("A host address carries no component, and a surface address does")
    func hostRoundTrip() {
        let host = CloudAddress(machineID: "vm-9")
        let parsed = CloudAddress(parsing: host.identifier)
        #expect(parsed?.machineID == "vm-9")
        #expect(parsed?.component == nil)
        #expect(CloudAddress(parsing: "vm-9") == nil)
        // A surface address reduces to its machine's host address.
        #expect(CloudAddress(machineID: "vm-9", component: "t-1").host == host)
    }
}

@Suite("Cloud workspace projection")
struct CloudWorkspaceProjectorTests {
    private func state(
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary],
        status: MobileMacConnectionStatus = .connected,
        isAuthoritative: Bool = true
    ) -> MacWorkspaceState {
        CloudWorkspaceProjector(
            machineID: "vm-1",
            displayName: "sleepy-teal-otter"
        ).hostState(
            workspaces: workspaces,
            terminals: terminals,
            status: status,
            isAuthoritative: isAuthoritative
        )
    }

    @Test("Each remote workspace becomes one row carrying its terminals")
    func rowsCarryTerminals() {
        let result = state(
            workspaces: [
                CloudWorkspaceSummary(id: "ws-1", name: "api", root: "/home/cmux/api"),
                CloudWorkspaceSummary(id: "ws-2", name: nil, root: "/home/cmux/web"),
            ],
            terminals: [
                CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1"),
                CloudTerminalSummary(id: "t-2", name: nil, workspaceID: "ws-2"),
            ]
        )

        #expect(result.workspaces.count == 2)
        #expect(result.workspaces[0].name == "api")
        #expect(result.workspaces[0].currentDirectory == "/home/cmux/api")
        #expect(result.workspaces[0].terminals.map(\.name) == ["zsh"])
        // A nameless workspace falls back to the last path component.
        #expect(result.workspaces[1].name == "web")
        // A nameless terminal falls back to its daemon id rather than blank.
        #expect(result.workspaces[1].terminals.map(\.name) == ["t-2"])
    }

    @Test("Rows and terminals are addressed in the Cloud namespace")
    func identifiersAreNamespaced() {
        let result = state(
            workspaces: [CloudWorkspaceSummary(id: "ws-1", name: "api")],
            terminals: [CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1")]
        )

        let row = try! #require(result.workspaces.first)
        #expect(CloudAddress.owns(row.id.rawValue))
        #expect(row.macDeviceID == CloudAddress(machineID: "vm-1").identifier)
        let terminal = try! #require(row.terminals.first)
        let parsed = try! #require(CloudAddress(parsing: terminal.id.rawValue))
        #expect(parsed.machineID == "vm-1")
        #expect(parsed.component == "t-1")
    }

    @Test("Terminals with no workspace are gathered instead of stranded")
    func orphanTerminalsAreReachable() {
        let result = state(
            workspaces: [CloudWorkspaceSummary(id: "ws-1", name: "api")],
            terminals: [
                CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1"),
                CloudTerminalSummary(id: "t-2", name: "stray", workspaceID: nil),
                CloudTerminalSummary(id: "t-3", name: "stray2", workspaceID: ""),
            ]
        )

        #expect(result.workspaces.count == 2)
        let gathered = try! #require(result.workspaces.last)
        #expect(gathered.name == "sleepy-teal-otter")
        #expect(gathered.terminals.map(\.name) == ["stray", "stray2"])
    }

    @Test("A machine with no workspaces contributes an empty host, not a row")
    func emptyCatalog() {
        let result = state(workspaces: [], terminals: [])
        #expect(result.workspaces.isEmpty)
        #expect(result.macDeviceID == CloudAddress(machineID: "vm-1").identifier)
    }

    @Test("Workspace mutation stays hidden, since the daemon answers none of it")
    func actionsAreHidden() {
        let result = state(
            workspaces: [CloudWorkspaceSummary(id: "ws-1", name: "api")],
            terminals: []
        )
        #expect(result.actionCapabilities == .none)
        #expect(!result.actionCapabilities.supportsWorkspaceActions)
        #expect(!result.actionCapabilities.supportsCloseActions)
    }

    @Test("Liveness and authority pass through for per-host presentation")
    func livenessPassesThrough() {
        let unreachable = state(workspaces: [], terminals: [], status: .unavailable, isAuthoritative: false)
        #expect(unreachable.status == .unavailable)
        #expect(!unreachable.workspaceSnapshotIsAuthoritative)

        let connected = state(
            workspaces: [CloudWorkspaceSummary(id: "ws-1")],
            terminals: [],
            status: .connected,
            isAuthoritative: true
        )
        #expect(connected.status == .connected)
        #expect(connected.workspaceSnapshotIsAuthoritative)
    }

    @Test("An unchanged catalog projects to an equal value, so the store can skip it")
    func projectionIsStable() {
        let workspaces = [CloudWorkspaceSummary(id: "ws-1", name: "api")]
        let terminals = [CloudTerminalSummary(id: "t-1", name: "zsh", workspaceID: "ws-1")]
        #expect(state(workspaces: workspaces, terminals: terminals)
            == state(workspaces: workspaces, terminals: terminals))
    }
}
