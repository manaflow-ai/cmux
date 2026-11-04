import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Settings > MCP Servers (plans/cmux-next/mcp-connect-DESIGN.md row 3c) through its service seam:
/// each change goes to acpmux once and the list is read again; a deep link only selects a row; a
/// key reaches the service and nothing else keeps it.
@MainActor
@Suite struct McpServersModelTests {
    @MainActor
    final class FakeService: McpServersServing {
        var rows: [McpServerConnection]
        var calls: [String] = []
        var keys: [String] = []
        var failure: McpServersFailure?
        var keyOutcome = McpKeyOutcome.connected
        var authorize = URL(string: "https://auth.example.com/authorize?state=s")!

        init(_ rows: [McpServerConnection]) { self.rows = rows }

        func connections() async throws -> [McpServerConnection] {
            calls.append("list")
            return rows
        }

        func setPolicy(_ policy: McpToolPolicy, tool: String, connection: String) async throws {
            calls.append("policy \(connection) \(tool) \(policy.rawValue)")
            if let failure { throw failure }
            rows = rows.map { row in
                guard row.id == connection else { return row }
                return McpServerConnection(
                    id: row.id, name: row.name, title: row.title, publisher: row.publisher, verified: row.verified,
                    url: row.url, auth: row.auth, hasSecret: row.hasSecret, scope: row.scope, state: row.state,
                    addedAt: row.addedAt,
                    tools: row.tools.map { $0.name == tool ? McpServerTool(name: tool, policy: policy) : $0 })
            }
        }

        func remove(connection: String) async throws {
            calls.append("remove \(connection)")
            if let failure { throw failure }
            rows.removeAll { $0.id == connection }
        }

        func signIn(connection: String) async throws -> URL {
            calls.append("signIn \(connection)")
            if let failure { throw failure }
            return authorize
        }

        func setKey(_ key: String, connection: String) async throws -> McpKeyOutcome {
            calls.append("key \(connection)")
            keys.append(key)
            if let failure { throw failure }
            return keyOutcome
        }

        func approveTools(connection: String) async throws -> [String] {
            calls.append("approve \(connection)")
            if let failure { throw failure }
            var approved: [String] = []
            rows = rows.map { row in
                guard row.id == connection else { return row }
                approved = row.held
                return McpServerConnection(
                    id: row.id, name: row.name, title: row.title, publisher: row.publisher, verified: row.verified,
                    url: row.url, auth: row.auth, hasSecret: row.hasSecret, scope: row.scope, state: row.state,
                    addedAt: row.addedAt, tools: row.tools, held: [])
            }
            return approved
        }

        func audit(limit: Int) async throws -> [String] {
            calls.append("audit \(limit)")
            if let failure { throw failure }
            return [#"{"event":"remove","id":"mcp_1"}"#]
        }
    }

    static let linear = McpServerConnection(row: [
        "id": "mcp_0000000000000001", "name": "linear", "title": "Linear", "publisher": "linear.app",
        "verified": true, "url": "https://mcp.linear.app/mcp", "auth": "oauth", "hasSecret": true,
        "scope": "chief", "state": "connected", "addedAt": 1_762_000_000_000,
        "tools": [["name": "create_issue", "policy": "ask"], ["name": "list_issues", "policy": "always"]],
    ])!
    static let keyed = McpServerConnection(row: [
        "id": "mcp_0000000000000002", "name": "weather", "title": "Weather", "publisher": "weather.example",
        "verified": false, "url": "https://weather.example/mcp", "auth": "key", "hasSecret": false,
        "scope": "everywhere", "state": "needsKey", "addedAt": 1, "tools": [],
    ])!

    @Test func rowsDecodeTheDaemonsFieldsAndNoSecret() throws {
        let rows = AcpmuxMcpServersService.connections(from: [
            "connections": [
                ["id": "mcp_0000000000000001", "name": "linear", "title": "Linear", "publisher": "linear.app",
                 "verified": true, "url": "https://mcp.linear.app/mcp", "auth": "oauth", "hasSecret": true,
                 "scope": "chief", "state": "connected", "addedAt": 5,
                 "tools": [["name": "create_issue", "policy": "never"], ["name": "odd", "policy": "sometimes"]]],
                ["name": "no-id"],
            ],
            "secretStore": "keychain",
        ])
        let row = try #require(rows.first)
        #expect(rows.count == 1, "a row without an id is dropped")
        #expect(row.url == "https://mcp.linear.app/mcp" && row.publisher == "linear.app" && row.verified)
        #expect(row.scope == "chief" && row.state == "connected" && row.addedAt == 5 && row.signsIn && !row.takesKey)
        #expect(row.tools == [McpServerTool(name: "create_issue", policy: .never), McpServerTool(name: "odd", policy: .ask)],
                "an unknown policy reads as ask, the daemon's default")
        #expect(row.matches("LINEAR") && row.matches("mcp_0000000000000001") && !row.matches("lin"))
    }

    @Test func signInOpensOnlyAnHttpsPageOrLoopback() {
        #expect(AcpmuxMcpServersService.authorizeURL(from: ["authorizeUrl": "https://a.example/authorize?x=1"]) != nil)
        #expect(AcpmuxMcpServersService.authorizeURL(from: ["authorizeUrl": "http://127.0.0.1:9/authorize"]) != nil)
        #expect(AcpmuxMcpServersService.authorizeURL(from: ["authorizeUrl": "http://evil.example/authorize"]) == nil)
        #expect(AcpmuxMcpServersService.authorizeURL(from: ["authorizeUrl": "file:///etc/passwd"]) == nil)
        #expect(AcpmuxMcpServersService.authorizeURL(from: ["authorizeUrl": "javascript:alert(1)"]) == nil)
        #expect(AcpmuxMcpServersService.authorizeURL(from: [:]) == nil)
    }

    @Test func auditLinesAreCompactSortedJSON() {
        let lines = AcpmuxMcpServersService.auditLines(from: ["lines": [["seq": 1, "event": "add"], "not an object"]])
        #expect(lines == [#"{"event":"add","seq":1}"#])
    }

    @Test func reloadReadsTheListAndADeepLinkOnlySelects() async {
        let service = FakeService([Self.linear, Self.keyed])
        let model = McpServersModel(service: service, openURL: { _ in Issue.record("a deep link opened a page") })
        #expect(model.isLoading)
        model.focus("weather")
        await model.reload()
        #expect(!model.isLoading && model.connections.count == 2)
        #expect(model.focusedID == Self.keyed.id && model.unknownReference == nil)
        model.focus("nope")
        #expect(model.focusedID == nil && model.unknownReference == "nope")
        model.focus(nil)
        #expect(model.focusedID == nil && model.unknownReference == nil)
        #expect(service.calls == ["list"], "focus changes nothing in acpmux")
    }

    @Test func policyChangeGoesOutOnceThenRereads() async {
        let service = FakeService([Self.linear])
        let model = McpServersModel(service: service, openURL: { _ in })
        await model.reload()
        await model.setPolicy(.never, tool: "create_issue", of: Self.linear.id)
        #expect(service.calls == ["list", "policy mcp_0000000000000001 create_issue never", "list"])
        #expect(model.connections.first?.tools.first == McpServerTool(name: "create_issue", policy: .never))
        #expect(model.busy.isEmpty && model.notice == nil)
    }

    @Test func removeDropsTheRowAndTheFocus() async {
        let service = FakeService([Self.linear, Self.keyed])
        let model = McpServersModel(service: service, openURL: { _ in })
        model.focus("linear")
        await model.reload()
        await model.remove(Self.linear.id)
        #expect(model.connections.map(\.id) == [Self.keyed.id])
        #expect(model.focusedID == nil && model.notice == .removed)
    }

    @Test func signInOpensTheAuthorizePageInABrowserTab() async {
        let service = FakeService([Self.linear])
        var opened: [URL] = []
        let model = McpServersModel(service: service, openURL: { opened.append($0) })
        await model.reload()
        await model.signIn(Self.linear.id)
        #expect(opened == [service.authorize] && model.notice == .signInOpened)

        service.failure = .refused
        await model.signIn(Self.linear.id)
        #expect(opened.count == 1 && model.notice == .failed, "a failed sign-in opens nothing")
    }

    @Test func aKeyGoesToTheServiceOnlyAndAnEmptyOneNever() async {
        let service = FakeService([Self.keyed])
        let model = McpServersModel(service: service, openURL: { _ in })
        await model.reload()
        #expect(await model.saveKey("   ", for: Self.keyed.id) == false)
        #expect(service.keys.isEmpty)
        #expect(await model.saveKey(" sk-123 ", for: Self.keyed.id))
        #expect(service.keys == ["sk-123"] && model.notice == .keySaved)
        #expect(!String(describing: model.notice as Any).contains("sk-123"))

        service.keyOutcome = .refused
        #expect(await model.saveKey("bad", for: Self.keyed.id) == false)
        #expect(model.notice == .keyRefused)
    }

    @Test func noPersonLineMeansUnavailableAndTheListStays() async {
        let service = FakeService([Self.linear])
        let model = McpServersModel(service: service, openURL: { _ in })
        await model.reload()
        service.failure = .unavailable
        await model.remove(Self.linear.id)
        #expect(model.notice == .unavailable && model.connections.count == 1)
    }

    @Test func auditShowsAndHides() async {
        let service = FakeService([])
        let model = McpServersModel(service: service, openURL: { _ in })
        await model.showAudit()
        #expect(model.auditLines == [#"{"event":"remove","id":"mcp_1"}"#])
        #expect(service.calls == ["audit \(McpServersModel.auditLimit)"])
        model.hideAudit()
        #expect(model.auditLines == nil)
    }

    @Test func heldToolsDecodeAndApprovingThemGoesOutOnceThenRereads() async throws {
        let changed = try #require(McpServerConnection(row: [
            "id": "mcp_0000000000000003", "name": "docs", "auth": "key", "hasSecret": true, "state": "connected",
            "tools": [["name": "get_doc", "policy": "ask"], ["name": "delete_doc", "policy": "ask"]],
            "held": ["delete_doc", 7, "get_doc"],
        ]))
        #expect(changed.held == ["delete_doc", "get_doc"], "a name that is not text is dropped")
        #expect(Self.linear.held.isEmpty, "a row without `held` holds nothing")

        let service = FakeService([changed])
        let model = McpServersModel(service: service, openURL: { _ in })
        await model.reload()
        await model.approveTools(changed.id)
        #expect(service.calls == ["list", "approve mcp_0000000000000003", "list"])
        #expect(model.connections.first?.held == [] && model.notice == .toolsApproved)

        service.failure = .refused
        await model.approveTools(changed.id)
        #expect(model.notice == .failed, "a refused approval says so and approves nothing")
    }

    @Test func theCLIsListCarriesTheHeldToolsAndNoSecret() {
        let row = McpServerConnection(
            id: "mcp_1", name: "docs", title: "Docs", publisher: "docs.example", verified: false,
            url: "https://docs.example/mcp", auth: "key", hasSecret: true, scope: "chat", state: "connected",
            addedAt: 3, tools: [McpServerTool(name: "get_doc", policy: .ask)], held: ["get_doc"])
        let json = McpServersControl.json(row)
        #expect(json.objectValue?["held"] == .array([.string("get_doc")]))
        #expect(json.objectValue?["key"] == nil && json.objectValue?["secret"] == nil)
    }

    @MainActor
    final class FakeHost: McpServersHost {
        var mcpServersEnvironment: AcpmuxEnvironment? { nil }
        var showsPage = true
        var shown: [Bool] = []
        var open = true
        var opened: [URL] = []
        func mcpServersShowPage(focus: Bool) -> Bool {
            shown.append(focus)
            return showsPage
        }
        func mcpServersPageIsOpen() -> Bool { open }
        func mcpServersOpenBrowserTab(_ url: URL) { opened.append(url) }
    }

    @Test func theCoordinatorOpensThePageAtAConnectionAndChangesNothing() async {
        let host = FakeHost()
        let service = FakeService([Self.linear, Self.keyed])
        let coordinator = McpServersCoordinator(host: host, dialogs: CmuxDialogCenter(), service: service)
        #expect(coordinator.show(connection: "weather", focus: false))
        #expect(host.shown == [false], "automation opens the tab without selecting it")
        let model = coordinator.model
        await model?.reload()
        #expect(model?.focusedID == Self.keyed.id)
        #expect(service.calls.allSatisfy { $0 == "list" }, "opening the page changes nothing in acpmux")

        coordinator.pageClosed()
        #expect(coordinator.model != nil, "another tab still shows the page")
        host.open = false
        coordinator.pageClosed()
        #expect(coordinator.model == nil)

        host.showsPage = false
        #expect(!coordinator.show(connection: nil, focus: true), "no window: refused")
    }

    @Test func theLiveServiceSendsNothingWithoutAPersonLine() async {
        let service = AcpmuxMcpServersService(open: { nil })
        await #expect(throws: McpServersFailure.unavailable) { try await service.remove(connection: "mcp_1") }
        await #expect(throws: McpServersFailure.unavailable) { _ = try await service.connections() }
    }
}
