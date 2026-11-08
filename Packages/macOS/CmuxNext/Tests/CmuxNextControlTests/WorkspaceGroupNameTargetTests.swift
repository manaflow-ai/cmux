@testable import CmuxNextControl
import Testing

/// A workspace group target answers to its exact name as well as its id
/// (`cmux workspace group create --parent Fleet --name "Mac minis"`), never to a prefix of the name.
struct WorkspaceGroupNameTargetTests {
    private func topology(_ groups: [(String, String)]) -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = true
        topology.workspaceGroups = groups.map { ControlWorkspaceGroupInfo(id: $0.0, name: $0.1, color: nil, isCollapsed: false) }
        return topology
    }

    @Test func anExactNameResolvesToItsGroup() throws {
        let resolved = try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspaceGroup", id: "Fleet"),
                                                          in: topology([("grp_1", "Fleet"), ("grp_2", "Docs")]))
        #expect(resolved.id == "grp_1")
    }

    @Test func aPrefixOfANameIsNotFound() {
        #expect(throws: ControlError.self) {
            try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspaceGroup", id: "Fle"), in: topology([("grp_1", "Fleet")]))
        }
    }

    @Test func twoGroupsOfOneNameAreAmbiguous() {
        #expect(throws: ControlError.self) {
            try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspaceGroup", id: "Fleet"),
                                               in: topology([("grp_1", "Fleet"), ("grp_2", "Fleet")]))
        }
    }

    @Test func anIdStillWins() throws {
        let resolved = try PublicIDTargetResolver.resolve(ControlTargetRef(kind: "workspaceGroup", id: "grp_2"),
                                                          in: topology([("grp_1", "grp_2"), ("grp_2", "Docs")]))
        #expect(resolved.id == "grp_2")
    }
}
