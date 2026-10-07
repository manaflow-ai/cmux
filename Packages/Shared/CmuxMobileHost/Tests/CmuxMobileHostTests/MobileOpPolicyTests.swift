import CmuxMobileHost
import CmuxMobileWire
import Testing

@Suite("Op policy")
struct MobileOpPolicyTests {
    let state = FakeDaemon.sample
    let policy = MobileOpPolicy(hostID: "h_mac1")

    func code(_ op: String, _ params: [String: JSONValue], policy: MobileOpPolicy? = nil) -> String? {
        if case .failure(let rejection) = (policy ?? self.policy).evaluate(op: op, params: .object(params), state: state) {
            return rejection.code
        }
        return nil
    }

    @Test func allowsRenameAndCloseOfOwnedObjects() throws {
        let rename = policy.evaluate(op: "workspace.rename", params: .object(["workspace": "ws_a1", "name": " Build "]), state: state)
        #expect(try rename.get() == .renameWorkspace(workspace: "ws_a1", name: "Build"))
        let close = policy.evaluate(op: "workspace.tab.close", params: .object(["tab": "tab_t1"]), state: state)
        #expect(try close.get() == .closeTab(tab: "tab_t1"))
    }

    @Test func deniesUnknownOps() {
        #expect(code("workspace.delete_everything", [:]) == "auth.forbidden")
        #expect(code("task.dispatch", ["prompt": "x"]) == "auth.forbidden")
    }

    @Test func deniesCommandBearingParamsOnEveryOp() {
        #expect(code("workspace.rename", ["workspace": "ws_a1", "name": "x", "command": "rm -rf /"]) == "auth.forbidden")
        #expect(code("workspace.tab.close", ["tab": "tab_t1", "initial_command": "id"]) == "auth.forbidden")
        let spawning = MobileOpPolicy(hostID: "h_mac1", allowsTerminalSpawn: true)
        #expect(code("workspace.tab.create", ["workspace": "ws_a1", "kind": "terminal", "cwd": "/tmp"], policy: spawning) == "auth.forbidden")
        #expect(code("workspace.create", ["host": "h_mac1", "env": ["BASH_ENV": "/tmp/x"]], policy: spawning) == "auth.forbidden")
        #expect(code("workspace.tab.create", ["workspace": "ws_a1", "kind": "browser", "url": "file:///etc"], policy: spawning) == "auth.forbidden")
    }

    @Test func refusesTerminalSpawnUntilVerified() throws {
        let result = policy.evaluate(op: "workspace.tab.create", params: .object(["workspace": "ws_a1", "kind": "terminal"]), state: state)
        guard case .failure(let rejection) = result else { Issue.record("spawn allowed"); return }
        #expect(rejection.code == "auth.forbidden")
        #expect(rejection.details?["reason"] == "spawn_unverified")
        #expect(code("workspace.create", ["host": "h_mac1"]) == "auth.forbidden")
        let spawning = MobileOpPolicy(hostID: "h_mac1", allowsTerminalSpawn: true)
        let allowed = spawning.evaluate(op: "workspace.tab.create", params: .object(["workspace": "ws_a1", "kind": "terminal"]), state: state)
        #expect(try allowed.get() == .createTab(workspace: "ws_a1", pane: nil, kind: .terminal, url: nil))
    }

    @Test func scopesIDsToThisHostsTree() {
        #expect(code("workspace.rename", ["workspace": "ws_zz9", "name": "x"]) == "workspace.not_found")
        #expect(code("workspace.tab.close", ["tab": "tab_zz9"]) == "workspace.tab_not_found")
        #expect(code("workspace.rename", ["workspace": "workspace:1", "name": "x"]) == "validation.invalid")
        #expect(code("workspace.tab.close", ["tab": "surface:2"]) == "validation.invalid")
    }

    @Test func refusesParamsOutsideTheSchema() {
        #expect(code("workspace.rename", ["workspace": "ws_a1", "name": "x", "focus": true]) == "validation.invalid")
        #expect(code("workspace.rename", ["workspace": "ws_a1", "name": ""]) == "validation.invalid")
    }
}

extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByBooleanLiteral,
    @retroactive ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
