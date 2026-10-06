@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

@Suite struct ControlRouterTests {
    func makeRouter(_ executor: RecordingExecutor = RecordingExecutor(), settings: (any ControlSettingsStore)? = nil) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: executor, settings: settings, configuration: .loadTolerant)
        router.updateCatalog(sampleCatalog())
        return router
    }

    /// `action.run` here tests validation and forwarding, so it answers once
    /// the handler ran (`wait: false`); waiting is ActionRunContractTests'.
    /// The main thread is shared with suites that stall it on purpose.
    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        var params = params
        if method == "action.run", params["wait"] == nil { params["wait"] = false }
        return await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    @Test func listAndDescribe() async throws {
        let router = makeRouter()
        let list = try await call(router, "action.list").get()
        #expect(list["count"] == 4)
        let first = try #require(list["actions"]?.arrayValue?.first)
        #expect(first["cli_name"] == "tab-group create")
        #expect(first["noun"] == "tab-group" && first["verb"] == "create")
        #expect(first["arguments"]?.arrayValue?.last?["choices"]?.arrayValue?.count == 2)

        let filtered = try await call(router, "action.list", ["noun": "workspace-group"]).get()
        #expect(filtered["count"] == 1)
        let available = try await call(router, "action.list", ["available_only": true]).get()
        #expect(available["count"] == 3)  // browserReload needs browser focus

        let byCLI = try await call(router, "action.describe", ["action": "tab-group   create"]).get()
        #expect(byCLI["action"]?["id"] == "tabGroup.create")
        let byAlias = try await call(router, "action.describe", ["action": "tab.group.new"]).get()
        #expect(byAlias["action"]?["id"] == "tabGroup.create")
        guard case .failure(let error) = await call(router, "action.describe", ["action": "nope"]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "not_found")
    }

    @Test func runValidatesAndForwards() async throws {
        let executor = RecordingExecutor()
        let router = makeRouter(executor)

        let result = try await call(router, "action.run", [
            "action": "tab-group create", "args": ["name": "API", "color": "Green"], "target": "tab:t9",
        ]).get()
        #expect(result["ran"] == true)
        #expect(executor.last == ControlActionRequest(
            actionID: "tabGroup.create",
            target: ControlTargetRef(kind: "tab", id: "t9"),
            arguments: ["name": .string("API"), "color": .string("green")]
        ))

        // Target kinds match without case, dashes, or underscores.
        _ = try await call(router, "action.run", ["action": "workspaceGroup.collapse", "target": "workspaceGroup:G1"]).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "workspace-group", id: "G1"))
        // A bare id takes the action's first target kind.
        _ = try await call(router, "action.run", ["action": "workspace-group collapse", "target": "G2"]).get()
        #expect(executor.last?.target == ControlTargetRef(kind: "workspace-group", id: "G2"))
        // Ints parse from strings (the CLI sends strings) and numbers.
        _ = try await call(router, "action.run", ["action": "selectWorkspaceByNumber", "args": ["index": "3"]]).get()
        #expect(executor.last?.arguments["index"] == .int(3))
        _ = try await call(router, "action.run", ["action": "selectWorkspaceByNumber", "args": ["index": 4]]).get()
        #expect(executor.last?.arguments["index"] == .int(4))
    }

    @Test func runRejectsBadInput() async throws {
        let executor = RecordingExecutor()
        let router = makeRouter(executor)
        let cases: [([String: JSONValue], String)] = [
            (["action": "tabGroup.create", "args": ["color": "teal"]], "invalid_params"),
            (["action": "tabGroup.create", "args": ["colour": "grey"]], "invalid_params"),
            (["action": "tabGroup.create", "target": "pane:p1"], "invalid_params"),
            (["action": "selectWorkspaceByNumber"], "invalid_params"),
            (["action": "selectWorkspaceByNumber", "args": ["index": 12]], "invalid_params"),
            (["action": "selectWorkspaceByNumber", "target": "workspace:w1", "args": ["index": 1]], "invalid_params"),
            (["action": "browserReload"], "unavailable"),
            (["action": "missing"], "not_found"),
            ([:], "invalid_params"),
        ]
        for (params, code) in cases {
            guard case .failure(let error) = await call(router, "action.run", params) else {
                Issue.record("expected \(code) for \(params)")
                continue
            }
            #expect(error.code == code, "\(params): \(error.message)")
        }
        #expect(executor.requests.withLock { $0.isEmpty })

        // A bare id containing a colon but no known kind stays an id.
        #expect(try ControlRouter.target(from: "tab:ab:cd", allowedKinds: ["tab"], knownKinds: ["tab"], action: "x").id == "ab:cd")
    }

    @Test func contextMaskDrivesAvailability() async throws {
        let router = makeRouter()
        router.updateContextMask(2)
        let result = try await call(router, "action.run", ["action": "browser reload"]).get()
        #expect(result["ran"] == true)
    }

    @Test func executorOutcomesMapToErrors() async {
        for (outcome, code) in [(ControlActionOutcome.notBound, "not_bound"), (.disabled, "disabled"), (.unavailable, "unavailable")] {
            let router = makeRouter(RecordingExecutor(outcome: outcome))
            guard case .failure(let error) = await call(router, "action.run", ["action": "workspace-group collapse", "target": "g"]) else {
                Issue.record("expected \(code)")
                continue
            }
            #expect(error.code == code)
        }
    }

    @Test func settingsGetSetUnset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = CmuxConfigFile(url: directory.appending(path: "cmux.json"))
        let router = makeRouter(settings: file)

        let missing = try await call(router, "settings.get", ["path": "appearance.density"]).get()
        #expect(missing["exists"] == false)
        _ = try await call(router, "settings.set", ["path": "appearance.density", "value": "comfortable"]).get()
        _ = try await call(router, "settings.set", ["path": "shortcuts.bindings.tabGroup.create", "value": "cmd+shift+g"]).get()
        let density = try await call(router, "settings.get", ["path": "appearance.density"]).get()
        #expect(density["value"] == "comfortable")
        let binding = try await call(router, "settings.get", ["path": ["shortcuts", "bindings", "tabGroup.create"]]).get()
        #expect(binding["value"] == "cmd+shift+g")
        _ = try await call(router, "settings.unset", ["path": "appearance.density"]).get()
        let root = try await call(router, "settings.get").get()
        #expect(root["value"]?["appearance"] == .object([:]))
        guard case .failure(let error) = await call(router, "settings.set", ["path": "a"]) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "invalid_params")
    }

    @Test func linesAndErrors() async throws {
        let router = makeRouter()
        #expect(await router.response(forLine: "ping") == "PONG")
        #expect(await router.response(forLine: "list_windows").hasPrefix("ERROR:"))
        let parseError = try JSONValue.parse(Data(await router.response(forLine: "{nope").utf8))
        #expect(parseError["error"]?["code"] == "parse_error")
        let unknown = try JSONValue.parse(Data(await router.response(forLine: #"{"id":7,"method":"workspace.list"}"#).utf8))
        #expect(unknown["id"] == 7)
        #expect(unknown["error"]?["code"] == "method_not_found")
        let ping = try JSONValue.parse(Data(await router.response(forLine: #"{"id":"a","method":"system.ping"}"#).utf8))
        #expect(ping["result"]?["app"] == "cmux-next")
        #expect(ping["result"]?["pong"] == true)
    }
}

@Suite struct ControlSocketPathTests {
    let home = URL(fileURLWithPath: "/Users/u")

    @Test func matchesTheOldConventions() {
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app.debug", tag: "My Tag", isDebugBuild: true, home: home) == "/tmp/cmux-debug-my-tag.sock")
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app.debug.ctl", tag: nil, isDebugBuild: true, home: home) == "/tmp/cmux-debug-ctl.sock")
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app.debug", tag: nil, isDebugBuild: true, home: home) == "/tmp/cmux-debug.sock")
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app.nightly", tag: nil, isDebugBuild: false, home: home) == "/tmp/cmux-nightly.sock")
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app.rc.x1", tag: nil, isDebugBuild: false, home: home) == "/tmp/cmux-rc-x1.sock")
        #expect(ControlSocketPath.shared.resolve(bundleID: "com.cmuxterm.app", tag: "ignored", isDebugBuild: false, home: home) == "/Users/u/.local/state/cmux/cmux.sock")
    }

    @Test func anyProcessOfThisUserIsAdmittedUnlessSomethingChoosesAMode() {
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: nil) == .automation)
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: "cmuxOnly") == .cmuxOnly)
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: ["CMUX_NEXT_SOCKET_MODE": "password"], configured: "cmuxOnly") == .password)
        #expect(ControlService.resolveAccessMode(explicit: .off, environment: ["CMUX_NEXT_SOCKET_MODE": "password"], configured: nil) == .off)
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: "bogus") == .automation)
    }

    @Test func parsesAccessModesWithLegacyAliases() {
        #expect(ControlService.parseAccessMode("cmuxOnly") == .cmuxOnly)
        #expect(ControlService.parseAccessMode("openAccess") == .allowAll)
        #expect(ControlService.parseAccessMode("notifications") == .automation)
        #expect(ControlService.parseAccessMode("allowAll") == .allowAll)
        #expect(ControlService.parseAccessMode("bogus") == nil)
    }
}
