import CmuxMobileHost
import CmuxMobileWire
import Foundation
import Testing

/// E3 additions (e3-workspaces.md section 3): `workspace.move`,
/// `workspace.group.rename`, `workspace.customize` and `workspace.groups.set`.
@Suite("Workspace move, group rename and customize")
struct WorkspaceOpsE3Tests {
    static let app = MobileWorkspaceGroup(id: "grp_app", name: "App", order: 0)
    static let ops = MobileWorkspaceGroup(id: "grp_ops", name: "Ops", order: 1)
    static let grouped = MobileWorkspaceState(host: "h_mac1", workspaces: [
        MobileWorkspace(id: "ws_a1", name: "a", order: 0, group: app, panes: []),
        MobileWorkspace(id: "ws_b2", name: "b", order: 1, group: app, panes: []),
        MobileWorkspace(id: "ws_c3", name: "c", order: 2, panes: []),
        MobileWorkspace(id: "ws_d4", name: "d", order: 3, panes: []),
    ], groups: [app, ops])

    let policy = MobileOpPolicy(hostID: "h_mac1")

    func evaluate(_ op: String, _ params: [String: JSONValue]) -> Result<MobileDaemonOp, MobileOpRejection> {
        policy.evaluate(op: op, params: .object(params), state: Self.grouped)
    }

    func code(_ op: String, _ params: [String: JSONValue]) -> String? {
        if case .failure(let rejection) = evaluate(op, params) { return rejection.code }
        return nil
    }

    @Test func moveResolvesGroupsInThisHostsTree() throws {
        #expect(try evaluate("workspace.move", ["workspace": "ws_c3", "group": "grp_app", "index": 1]).get()
            == .moveWorkspace(workspace: "ws_c3", group: .group("grp_app"), index: 1))
        // An empty group is a valid destination: it is listed in `groups`.
        #expect(try evaluate("workspace.move", ["workspace": "ws_c3", "group": "grp_ops", "index": 0]).get()
            == .moveWorkspace(workspace: "ws_c3", group: .group("grp_ops"), index: 0))
        #expect(try evaluate("workspace.move", ["workspace": "ws_a1", "group": .null, "index": 0]).get()
            == .moveWorkspace(workspace: "ws_a1", group: .ungrouped, index: 0))
        #expect(try evaluate("workspace.move", ["workspace": "ws_a1", "index": .double(1)]).get()
            == .moveWorkspace(workspace: "ws_a1", group: .keep, index: 1))
        #expect(code("workspace.move", ["workspace": "ws_a1", "group": "grp_nope", "index": 0]) == "workspace.group_not_found")
        #expect(code("workspace.move", ["workspace": "ws_zz9", "index": 0]) == "workspace.not_found")
        #expect(code("workspace.move", ["workspace": "ws_a1", "index": -1]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1", "index": .double(1.5)]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1"]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1", "group": "../etc", "index": 0]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1", "group": 3, "index": 0]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1", "index": 0, "window": "w1"]) == "validation.invalid")
        #expect(code("workspace.move", ["workspace": "ws_a1", "index": 0, "command": "sh"]) == "auth.forbidden")
    }

    @Test func groupRenameIsScopedAndValidated() throws {
        #expect(try evaluate("workspace.group.rename", ["group": "grp_ops", "name": "  Infra "]).get()
            == .renameGroup(group: "grp_ops", name: "Infra"))
        #expect(code("workspace.group.rename", ["group": "grp_x", "name": "X"]) == "workspace.group_not_found")
        #expect(code("workspace.group.rename", ["group": "grp_app", "name": "   "]) == "validation.invalid")
        #expect(code("workspace.group.rename", ["group": "grp_app"]) == "validation.invalid")
        #expect(code("workspace.group.rename", ["group": "grp_app", "name": "X", "color": "red"]) == "validation.invalid")
        #expect(code("workspace.group.rename", ["group": "grp_app", "name": "X", "env": ["A": "1"]]) == "auth.forbidden")
    }

    @Test func customizeValidatesColorsAndIcons() throws {
        #expect(try evaluate("workspace.customize", ["workspace": "ws_a1", "color": "blue", "icon": "hammer.fill"]).get()
            == .customizeWorkspace(workspace: "ws_a1", color: .set("blue"), icon: .set("hammer.fill")))
        #expect(try evaluate("workspace.customize", ["workspace": "ws_a1", "color": "#1A2b3C"]).get()
            == .customizeWorkspace(workspace: "ws_a1", color: .set("#1A2b3C"), icon: .unchanged))
        #expect(try evaluate("workspace.customize", ["workspace": "ws_a1", "color": .null, "icon": .null]).get()
            == .customizeWorkspace(workspace: "ws_a1", color: .clear, icon: .clear))
        for bad: JSONValue in ["Blue", "#12345", "#12345g", "1red", "red;rm", .int(3), ""] {
            #expect(code("workspace.customize", ["workspace": "ws_a1", "color": bad]) == "validation.invalid")
        }
        for bad: JSONValue in ["Hammer", "hammer fill", "$(id)", "", .bool(true), .string(String(repeating: "a", count: 129))] {
            #expect(code("workspace.customize", ["workspace": "ws_a1", "icon": bad]) == "validation.invalid")
        }
        #expect(code("workspace.customize", ["workspace": "ws_x9", "icon": "star"]) == "workspace.not_found")
        #expect(code("workspace.customize", ["workspace": "ws_a1", "name": "x"]) == "validation.invalid")
        #expect(code("workspace.customize", ["workspace": "ws_a1", "shell": "/bin/sh"]) == "auth.forbidden")
    }

    @Test func capsAreAdvertised() {
        let caps = MobileHostConfiguration.defaultCaps
        #expect(caps.contains("workspace.move") && caps.contains("workspace.group.rename") && caps.contains("workspace.customize"))
    }

    @Test func diffSendsGroupsAndMetadata() throws {
        var next = Self.grouped
        next.groups?[1].name = "Infra"
        let changes = WorkspaceDiff(from: Self.grouped, to: next).changes
        #expect(changes.map(\.op) == ["workspace.groups.set"])
        let groups = try #require(try changes.first?.params["groups"]?.decode(as: [MobileWorkspaceGroup].self))
        #expect(groups.map(\.name) == ["App", "Infra"])
        next = Self.grouped
        next.workspaces[2].icon = "star"
        #expect(WorkspaceDiff(from: Self.grouped, to: next).changes.map(\.op) == ["workspace.upsert"])
        next = Self.grouped
        next.workspaces[2].group = Self.ops
        #expect(WorkspaceDiff(from: Self.grouped, to: next).changes.map(\.op) == ["workspace.upsert"])
    }

    @Test func executorMovesRenamesAndCustomizes() async throws {
        let daemon = FakeDaemon(state: Self.grouped)
        let owner = WorkspaceStreamOwner(hostID: "h_mac1", daemon: daemon, startSeq: 10)
        let executor = MobileOpExecutor(policy: policy, owner: owner, daemon: daemon, authorizer: AllowAllAuthorizer())
        let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u_1", platform: "ios", appVersion: "1")
        func run(_ op: String, _ params: [String: JSONValue], key: String) async -> MobileOpReply {
            await executor.execute(OpFrame(op: op, params: .object(params), idempotencyKey: key), principal: principal)
        }
        let move = await run("workspace.move", ["workspace": "ws_d4", "group": "grp_app", "index": 0], key: "move-key-0001")
        guard case .result = move.outcome else { Issue.record("move refused: \(move.outcome)"); return }
        let order = await daemon.state.workspaces.sorted { $0.order < $1.order }
        #expect(order.map(\.id) == ["ws_d4", "ws_a1", "ws_b2", "ws_c3"])
        #expect(order.first?.group?.id == "grp_app")
        let replay = await run("workspace.move", ["workspace": "ws_d4", "group": "grp_app", "index": 0], key: "move-key-0001")
        #expect(replay.replayed)
        let rename = await run("workspace.group.rename", ["group": "grp_app", "name": "Apps"], key: "rename-key-01")
        guard case .result = rename.outcome else { Issue.record("rename refused"); return }
        let customize = await run("workspace.customize", ["workspace": "ws_c3", "color": "red", "icon": "star"], key: "custom-key-01")
        guard case .result = customize.outcome else { Issue.record("customize refused"); return }
        let state = await daemon.state
        #expect(state.workspaces.first { $0.id == "ws_c3" }?.color == "red")
        #expect(state.workspaces.first { $0.id == "ws_c3" }?.icon == "star")
        #expect(state.groups?.first?.name == "Apps")
        #expect(await daemon.ops.count == 3)
    }
}
