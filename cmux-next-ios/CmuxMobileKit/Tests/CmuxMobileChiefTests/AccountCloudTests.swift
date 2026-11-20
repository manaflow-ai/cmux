import Foundation
import Testing
@testable import CmuxMobileChief

/// The new Mac rows the account's own Cloud calls carry (cmux#25834, Mac features after
/// 2026-10-26): Automations, Make Primary Chief and Connect GitHub, at the
/// HTTP boundary: what the phone sends the service and what it makes of the answers.
@MainActor
@Suite(.serialized) struct AccountCloudTests {
    /// A scripted service: each request is recorded, and answered by its `op` (or its path).
    final class Service: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answers: [String: (status: Int, body: String)] = [:]
        nonisolated(unsafe) static var seen: [(path: String, query: String?, body: [String: Any])] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let path = request.url?.path ?? ""
            let key = object["op"] as? String ?? path
            let answer = Self.lock.withLock {
                Self.seen.append((path, request.url?.query, object))
                return Self.answers[key] ?? (404, "{}")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, // crash-allow: test stub
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

        static func reset(_ answers: [String: (Int, String)]) {
            lock.withLock {
                self.answers = answers.mapValues { (status: $0.0, body: $0.1) }
                seen = []
            }
        }

        static var ops: [String] { lock.withLock { seen.compactMap { $0.body["op"] as? String } } }
        static func params(_ op: String) -> [String: Any]? {
            lock.withLock { seen.last { $0.body["op"] as? String == op }?.body["params"] as? [String: Any] }
        }
        static func request(_ op: String) -> [String: Any]? { lock.withLock { seen.last { $0.body["op"] as? String == op }?.body } }
    }

    static func account() -> AccountCloud {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Service.self]
        let session = URLSession(configuration: configuration)
        let base = URL(string: "https://cloud-api-staging.cmux.dev")!
        return AccountCloud(http: ChiefCloudHTTP(base: base, accessToken: { _ in "token" }, session: session))
    }

    static let list = #"{"value":{"owner":"team_1","revision":"r","automations":[{"id":"auto_a","name":"Morning summary","enabled":true,"version":3,"next_run_at":4102444800000,"triggers":[{"spec":{"type":"cron","expr":"0 9 * * 1-5","tz":"UTC"}}],"body":{"prompt":"summarize my PRs"}},{"id":"auto_b","name":"Nightly","enabled":false,"version":1,"next_run_at":null,"triggers":[{"spec":{"type":"manual"}}],"body":{"prompt":"x"}},{"id":"auto_c","name":"Broken","enabled":true,"version":2,"next_run_at":null,"triggers":[{"spec":{"type":"every","seconds":1800}}],"body":{"command":"make"}}]}}"#
    static let runs = #"{"value":{"revision":"r","runs":[{"id":"run_1","automation":"auto_c","state":"failed","created_at":1000,"started_at":1000,"finished_at":2000,"error":{"code":"exit_7","message":"exit 7"},"trigger":{"id":null,"type":"every"}},{"id":"run_2","automation":"auto_a","state":"succeeded","created_at":500,"started_at":500,"finished_at":900,"error":null,"trigger":{"id":null,"type":"cron"}}]}}"#

    @Test func automationsLoadInTheMacsSections() async {
        Service.reset(["automation.list": (200, Self.list), "automation.runs.list": (200, Self.runs)])
        let account = Self.account()
        let model = CloudAutomationsModel { account }
        await model.load()
        #expect(model.phase == .loaded)
        let sections = model.sections(now: Date(timeIntervalSince1970: 0))
        #expect(sections.map(\.0) == [.needsYou, .later, .paused])
        #expect(sections[0].1.map(\.id) == ["auto_c"])
        #expect(sections[0].1.first?.runs.first?.reason == "exit 7")
        #expect(model.automation("auto_a")?.schedule == "cron 0 9 * * 1-5 (UTC)")
        #expect(model.automation("auto_c")?.schedule == "every 30m")
        #expect(model.automation("auto_c")?.task == "make")
        // Reads go to /v1/read.
        #expect(Service.lock.withLock { Service.seen.allSatisfy { $0.path == "/v1/read" } })
    }

    @Test func runPauseAndDeleteAreTheAccountsOwnOps() async throws {
        Service.reset(["automation.list": (200, Self.list), "automation.runs.list": (200, Self.runs),
                       "automation.run": (200, #"{"value":{"id":"run_9"}}"#),
                       "automation.update": (200, #"{"value":{}}"#), "automation.delete": (200, #"{"value":{"automation":"auto_b"}}"#)])
        let account = Self.account()
        let model = CloudAutomationsModel { account }
        await model.load()
        let morning = try #require(model.automation("auto_a"))
        await model.runNow(morning)
        #expect(Service.params("automation.run")?["automation"] as? String == "auto_a")
        let run = try #require(Service.request("automation.run"))
        #expect(run["origin"] as? String == "user")
        #expect((run["idempotency_key"] as? String)?.hasPrefix("run-auto_a-") == true)
        await model.setEnabled(morning, false)
        let update = try #require(Service.params("automation.update"))
        #expect(update["enabled"] as? Bool == false && update["expected_version"] as? Int == 3 && update["automation"] as? String == "auto_a")
        let nightly = try #require(model.automation("auto_b"))
        await model.delete(nightly)
        #expect(Service.params("automation.delete")?["automation"] as? String == "auto_b")
        #expect(Service.lock.withLock { Service.seen.filter { ($0.body["op"] as? String)?.hasPrefix("automation.") == true && $0.body["idempotency_key"] != nil }
            .allSatisfy { $0.path == "/v1/ops" } })
        #expect(model.failure == nil)
    }

    @Test func aRefusedPauseRollsBackAndSaysWhy() async throws {
        Service.reset(["automation.list": (200, Self.list), "automation.runs.list": (200, Self.runs),
                       "automation.update": (409, #"{"error":{"code":"version.conflict","message":"It changed elsewhere."}}"#)])
        let account = Self.account()
        let model = CloudAutomationsModel { account }
        await model.load()
        let morning = try #require(model.automation("auto_a"))
        await model.setEnabled(morning, false)
        #expect(model.automation("auto_a")?.enabled == true)
        #expect(model.failure == "It changed elsewhere.")
    }

    @Test func deletingTheLastAutomationKeepsTheLoadedPage() async throws {
        Service.reset(["automation.list": (200, #"{"value":{"automations":[{"id":"auto_a","name":"A","enabled":true,"version":1,"triggers":[],"body":{}}]}}"#),
                       "automation.runs.list": (200, #"{"value":{"runs":[]}}"#),
                       "automation.delete": (200, #"{"value":{"automation":"auto_a"}}"#)])
        let account = Self.account()
        let model = CloudAutomationsModel { account }
        await model.load()
        let row = try #require(model.automation("auto_a"))
        Service.reset(["automation.list": (200, #"{"value":{"automations":[]}}"#), "automation.runs.list": (200, #"{"value":{"runs":[]}}"#),
                       "automation.delete": (200, #"{"value":{"automation":"auto_a"}}"#)])
        await model.delete(row)
        #expect(model.phase == .loaded)
        #expect(model.automations.isEmpty)
        // The reload the page change cancels (the live bug): the page stays loaded, never on Loading.
        let reload = Task { await model.load() }
        reload.cancel()
        await reload.value
        #expect(model.phase == .loaded)
        #expect(Service.ops.contains("automation.delete"))
    }

    @Test func aBusyPageChangesNothingItCannotSend() async throws {
        Service.reset(["automation.list": (200, Self.list), "automation.runs.list": (200, Self.runs)])
        let model = CloudAutomationsModel { nil }
        let row = CloudAutomation(id: "auto_a", name: "A", schedule: "manual", task: "", enabled: true, version: 1, nextRun: nil)
        await model.setEnabled(row, false)
        await model.delete(row)
        #expect(Service.ops.isEmpty)
        #expect(!model.canAct)
    }

    @Test func anErroredGitHubConnectionCanConnectAgain() {
        let value = Data(#"{"connections":[{"provider":"github","status":"error"}],"providers":[{"provider":"github","configured":true}]}"#.utf8)
        #expect(GitHubConnect.state(value) == .notConnected)
    }

    @Test func signedOutSaysSo() async {
        let model = CloudAutomationsModel { nil }
        await model.load()
        #expect(model.phase == .failed("Sign in to cmux to see your Cloud automations."))
    }

    @Test func makePrimaryWritesIsDefaultAtTheChiefsRevision() async throws {
        Service.reset(["chief.update": (200, #"{"value":{"id":"agent_b","rev":5,"is_default":true}}"#)])
        let chief = CloudChief(id: "agent_b", displayName: "Second", isDefault: false, mainConversation: "conv_b", rev: 4, brainPlace: nil)
        try await ChiefSources.makePrimary(Self.account().http, chief: chief)
        let request = try #require(Service.request("chief.update"))
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["chief"] as? String == "agent_b" && params["expected_rev"] as? Int == 4 && params["is_default"] as? Bool == true)
        #expect(request["origin"] as? String == "user")
        #expect(Service.lock.withLock { Service.seen.last?.path } == "/v1/ops")
    }

    @Test func makePrimaryRereadsTheRevisionOnceAfterAConflict() async throws {
        Service.reset(["chief.update": (409, #"{"error":{"code":"revision.conflict","message":"stale"}}"#),
                       "chief.list": (200, #"{"value":{"chiefs":[{"id":"agent_b","rev":7,"is_default":true,"display_name":"Second"}]}}"#)])
        let chief = CloudChief(id: "agent_b", displayName: "Second", isDefault: false, mainConversation: "conv_b", rev: 4, brainPlace: nil)
        // The fresh record is already primary (another device made it so): done.
        try await ChiefSources.makePrimary(Self.account().http, chief: chief)
        #expect(Service.ops == ["chief.update", "chief.list"])
    }

    @Test func connectGitHubOpensOnlyTheAppsInstallationPage() async {
        Service.reset(["integration.list": (200, #"{"value":{"connections":[],"providers":[{"provider":"github","configured":true}]}}"#),
                       "integration.connect": (200, #"{"value":{"authorize_url":"https://github.com/apps/cmux-dev/installations/new?state=a.b.c","connection":{"id":"conn_1"}}}"#)])
        let account = Self.account()
        var opened: [URL] = []
        let model = GitHubConnect(account: { account }, open: { opened.append($0) })
        await model.connect()
        #expect(opened.map(\.absoluteString) == ["https://github.com/apps/cmux-dev/installations/new?state=a.b.c"])
        #expect(Service.params("integration.connect")?["provider"] as? String == "github")
        #expect(model.state == .pending)
        #expect(GitHubConnect.installationURL("https://evil.example/apps/x/installations/new") == nil)
        #expect(GitHubConnect.installationURL("https://github.com/login/oauth/authorize") == nil)
    }

    @Test func connectGitHubDoesNothingWhenConnected() async {
        Service.reset(["integration.list": (200, #"{"value":{"connections":[{"provider":"github","status":"active","account_login":"octo"}],"providers":[{"provider":"github","configured":true}]}}"#)])
        let account = Self.account()
        var opened: [URL] = []
        let model = GitHubConnect(account: { account }, open: { opened.append($0) })
        await model.connect()
        #expect(opened.isEmpty)
        #expect(model.state == .connected(["octo"]))
        #expect(Service.ops == ["integration.list"])
    }
}

/// Delete Conversation from List and Show Hidden Conversations, kept per account.
@MainActor
@Suite struct HomeHiddenConversationsTests {
    static func row(_ id: String, at seconds: TimeInterval) -> MacHomeRow {
        let stamp = Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return MacHomeRow(wire: ["id": id, "kind": "direct", "name": id, "activity_at": stamp])! // crash-allow: test fixture
    }

    @Test func aHiddenRowComesBackWithANewerMessageAndPerAccount() throws {
        let defaults = try #require(UserDefaults(suiteName: "hidden-\(UUID().uuidString)"))
        let hidden = HomeHiddenConversations(defaults: defaults)
        hidden.use(account: "user_a")
        let rows = [Self.row("c1", at: 100), Self.row("c2", at: 100)]
        hidden.hide(rows[0])
        #expect(hidden.visible(rows).map(\.id) == ["c2"])
        #expect(hidden.hiddenCount(in: rows) == 1)
        // A newer message brings it back.
        #expect(hidden.visible([Self.row("c1", at: 101)]).map(\.id) == ["c1"])
        // Another account has its own list; the first account's comes back from disk.
        hidden.use(account: "user_b")
        #expect(hidden.visible(rows).count == 2)
        let again = HomeHiddenConversations(defaults: defaults)
        again.use(account: "user_a")
        #expect(again.visible(rows).map(\.id) == ["c2"])
        again.showAll()
        #expect(again.visible(rows).count == 2)
    }
}
