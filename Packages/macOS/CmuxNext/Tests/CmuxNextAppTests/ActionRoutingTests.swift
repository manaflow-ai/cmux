import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// An action whose explicit target lives on another machine goes to that
/// machine's daemon, not the active window's.
@MainActor
@Suite struct ActionRoutingTests {
    static func tree(key: String, pane: Int, surface: Int, tabResource: String) throws -> DaemonTree {
        let json = """
        {"generation":"g1","workspace_revision":1,"workspaces":[{"active":true,"id":1,"key":"\(key)","name":"w",
        "screens":[{"active":true,"id":2,"layout":{"pane":\(pane),"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":\(pane),"name":null,
        "tabs":[{"kind":"pty","name":"t","surface":\(surface),"dead":false,"tab_resource_id":"\(tabResource)"}]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    @Test func explicitTargetsResolveToTheirOwnMachine() throws {
        let local = DaemonService()
        let cloud = DaemonService(machineID: "vm-1")
        local.store.apply(snapshot: try Self.tree(key: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a11", pane: 3, surface: 4,
                                                  tabResource: "tab_00000000000000000000000000000011"))
        cloud.store.apply(snapshot: try Self.tree(key: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a22", pane: 3, surface: 4,
                                                  tabResource: "tab_00000000000000000000000000000022"))
        let daemons = [local, cloud]
        func route(_ kind: ActionTargetKind, _ id: String) -> DaemonService? {
            ActionRouting.daemon(for: ActionInvocation(target: ActionTargetRef(kind: kind, id: id)), daemons: daemons, windowMachine: { _ in nil })
        }
        let cloudWorkspace = try #require(cloud.store.workspaces.first)
        let cloudTab = try #require(cloudWorkspace.screens.first?.panes.first?.tabs.first)
        let cloudPane = try #require(cloudWorkspace.screens.first?.panes.first)
        #expect(route(.workspace, cloudWorkspace.id) === cloud)
        #expect(route(.tab, cloudTab.id) === cloud)
        #expect(route(.pane, cloudPane.id) === cloud)
        #expect(route(.machine, "vm-1") === cloud)
        #expect(route(.machine, "local") === local)
        let localWorkspace = try #require(local.store.workspaces.first)
        #expect(route(.workspace, localWorkspace.id) === local)
        // A workspace argument routes when there is no target.
        let byArgument = ActionRouting.daemon(for: ActionInvocation(arguments: ["workspace": .target(ActionTargetRef(kind: .workspace, id: cloudWorkspace.id))]),
                                              daemons: daemons, windowMachine: { _ in nil })
        #expect(byArgument === cloud)
        #expect(ActionRouting.daemon(for: ActionInvocation(), daemons: daemons, windowMachine: { _ in nil }) == nil)
        #expect(route(.workspace, "missing") == nil)
    }
}
