@testable import CmuxNextSidebar
import Testing

/// Leo, 2026-11-09: "also i noticed tens of seconds after restarting to update the sidebar kinda reshuffled or something
/// weird". Until the home session's owner serves, the sidebar keeps the order it drew at launch (the Rust rule
/// `sidebar_launch_order`); when the owner serves, the hold ends with one change to the live order.
@MainActor @Suite struct SidebarLaunchOrderHoldTests {
    private let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private func section(_ ids: [String], group: (id: String, members: [String])? = nil) -> SidebarSection {
        var nodes = ids.map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0, directory: "~")) }
        if let group {
            let members = group.members.map { SidebarWorkspace(id: WorkspaceID($0), title: $0, directory: "~") }
            nodes.append(.group(SidebarGroup(id: GroupID(group.id), name: group.id, workspaces: members)))
        }
        return SidebarSection(kind: .machine(machine), nodes: nodes)
    }

    private func drawn(_ model: SidebarModel) -> [String] {
        model.sections[0].nodes.map { node in
            switch node {
            case let .workspace(ws): ws.id.rawValue
            case let .group(group): "g:" + group.id.rawValue
            case let .item(item): "i:" + item.id
            }
        }
    }

    private func members(_ model: SidebarModel) -> [String] {
        model.sections[0].nodes.compactMap { if case let .group(group) = $0 { group } else { nil } }.first?.workspaces.map(\.id.rawValue) ?? []
    }

    @Test func aReorderedProvisionalPassKeepsTheOrderDrawnAtLaunch() {
        let model = SidebarModel()
        model.holdsLaunchOrder = true
        model.setSections([section(["a", "b", "c"])])
        model.setSections([section(["c", "a", "b"])])
        #expect(drawn(model) == ["a", "b", "c"])
    }

    @Test func aNewRowGoesAfterTheRowItFollows() {
        let model = SidebarModel()
        model.holdsLaunchOrder = true
        model.setSections([section(["a", "b", "c"])])
        model.setSections([section(["c", "a", "d", "b"])])
        #expect(drawn(model) == ["a", "d", "b", "c"])
    }

    @Test func rowsDrawnBeforeTheHoldStartsKeepTheirOrder() {
        let model = SidebarModel()
        model.setSections([section(["a", "b", "c"])]) // the window's saved rows, drawn first
        model.holdsLaunchOrder = true
        model.setSections([section(["b", "c", "a"])])
        #expect(drawn(model) == ["a", "b", "c"])
    }

    @Test func aGroupKeepsItsMembersDrawnOrder() {
        let model = SidebarModel()
        model.holdsLaunchOrder = true
        model.setSections([section(["a"], group: ("grp", ["x", "y", "z"]))])
        model.setSections([section(["a"], group: ("grp", ["z", "x", "y"]))])
        #expect(members(model) == ["x", "y", "z"])
    }

    @Test func theOwnerServingEndsTheHoldWithTheLiveOrder() {
        let model = SidebarModel()
        model.holdsLaunchOrder = true
        model.setSections([section(["a", "b", "c"], group: ("grp", ["x", "y"]))])
        model.setSections([section(["c", "a", "b"], group: ("grp", ["y", "x"]))])
        #expect(drawn(model) == ["a", "b", "c", "g:grp"])
        model.holdsLaunchOrder = false
        #expect(drawn(model) == ["c", "a", "b", "g:grp"])
        #expect(members(model) == ["y", "x"])
        // After the hold, a pass shows its own order again.
        model.setSections([section(["b", "c", "a"])])
        #expect(drawn(model) == ["b", "c", "a"])
    }

    @Test func aMoveThePersonAskedForShowsDuringTheHold() {
        let model = SidebarModel()
        model.holdsLaunchOrder = true
        model.setSections([section(["a", "b", "c"])])
        model.noteUserIntent()
        model.setSections([section(["b", "a", "c"])])
        #expect(drawn(model) == ["b", "a", "c"])
        model.userIntentClock = { .now + .seconds(60) }
        model.setSections([section(["c", "a", "b"])])
        #expect(drawn(model) == ["b", "a", "c"])
    }

    @Test func withoutTheHoldAPassShowsItsOwnOrder() {
        let model = SidebarModel()
        model.setSections([section(["a", "b", "c"])])
        model.setSections([section(["c", "a", "b"])])
        #expect(drawn(model) == ["c", "a", "b"])
    }
}
