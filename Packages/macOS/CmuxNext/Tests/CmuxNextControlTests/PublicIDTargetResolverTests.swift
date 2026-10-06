@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `action.run` targets take the public ids the CLI prints (`ws_…`, `tab_…`,
/// `term_…`) or a unique prefix, and reach the handler as model ids. A
/// workspace's model id is its durable key, so `ws_…` must be mapped.
@Suite struct PublicIDTargetResolverTests {
    func topology() -> ControlTopology {
        var topology = ControlSnapshot.sample().topology
        topology.workspaces[0].resourceID = "ws_0a1b2c"
        topology.workspaces[0].screens[0].panes[0].tabs[0].terminalID = "term_77aa"
        var second = topology.workspaces[0]
        second.id = "key-2"
        second.resourceID = "ws_0a9f00"
        second.screens = []
        topology.workspaces.append(second)
        return topology
    }

    @Test func publicIDsAndUniquePrefixesResolveToModelIDs() throws {
        let topology = topology()
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "ws_0a1b2c"), in: topology).id == "ws-1")
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "ws_0a9"), in: topology).id == "key-2")
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "tab", id: "term_77"), in: topology).id == "tab-1")
        // Model ids still work; an id that names nothing is not found once
        // the topology is loaded, and kinds it does not list pass through.
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "key-2"), in: topology).id == "key-2")
        #expect(throws: ControlError.self) { try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "pane", id: "nope"), in: topology) }
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "column", id: "c9"), in: topology).id == "c9")
        var unloaded = topology
        unloaded.isLoaded = false
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "pane", id: "nope"), in: unloaded).id == "nope")
    }

    @Test func windowsAnswerToTheirTypedIDAndTheirKey() throws {
        var topology = topology()
        let key = "8d1f0c3e-5a51-4c55-9f0e-6e2f6a4f9c01"
        topology.windows = [ControlWindowInfo(id: key, workspaceID: "ws-1", isKey: true, isVisible: true, focusedPaneID: nil)]
        let typed = "win_8d1f0c3e5a514c559f0e6e2f6a4f9c01"
        #expect(topology.windows[0].publicID == typed)
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "window", id: typed), in: topology).id == key)
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "window", id: key), in: topology).id == key)
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "window", id: "win_8d1f"), in: topology).id == key)
        #expect(throws: ControlError.self) { try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "window", id: "win_ffff"), in: topology) }
    }

    @Test func topologyJSONPrintsPublicIDsFirst() throws {
        var topology = topology()
        topology.windows = [ControlWindowInfo(id: "8d1f0c3e-5a51-4c55-9f0e-6e2f6a4f9c01", workspaceID: "ws-1", workspaceIDs: ["ws-1", "key-2"],
                                              isKey: true, isVisible: true, focusedPaneID: "pane-1")]
        topology.focus = ControlFocus(windowID: "8d1f0c3e-5a51-4c55-9f0e-6e2f6a4f9c01", workspaceID: "ws-1", paneID: "pane-1", tabID: "tab-1")
        topology.workspaces[0].screens[0].panes[0].tabs[0].terminalResourceID = "term_resource"
        topology.daemonSequence = 42
        let json = topology.json
        let workspace = try #require(json["workspaces"]?.arrayValue?.first)
        #expect(workspace["id"] == "ws_0a1b2c")
        #expect(workspace["key"] == "ws-1")
        let window = try #require(json["windows"]?.arrayValue?.first)
        #expect(window["id"] == "win_8d1f0c3e5a514c559f0e6e2f6a4f9c01")
        #expect(window["workspace"] == "ws_0a1b2c")
        #expect(window["workspaces"] == ["ws_0a1b2c", "ws_0a9f00"])
        #expect(json["focus"]?["window"] == "win_8d1f0c3e5a514c559f0e6e2f6a4f9c01")
        #expect(json["focus"]?["workspace"] == "ws_0a1b2c")
        #expect(json["sequence"] == 42)
        let tab = try #require(workspace["screens"]?.arrayValue?.first?["panes"]?.arrayValue?.first?["tabs"]?.arrayValue?.first)
        #expect(tab["terminal"] == "term_resource")
        #expect(tab["terminal_key"] == "term_77aa")
    }

    @Test func anAmbiguousPrefixNamesEveryCandidate() {
        #expect(throws: ControlError.self) {
            try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "ws_0a"), in: topology())
        }
    }
}
