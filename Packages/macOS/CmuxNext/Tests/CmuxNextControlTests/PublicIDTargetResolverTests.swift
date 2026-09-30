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
        // Model ids still work, and an unknown id reaches the handler as given.
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "key-2"), in: topology).id == "key-2")
        #expect(try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "pane", id: "nope"), in: topology).id == "nope")
    }

    @Test func anAmbiguousPrefixNamesEveryCandidate() {
        #expect(throws: ControlError.self) {
            try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspace", id: "ws_0a"), in: topology())
        }
    }
}
