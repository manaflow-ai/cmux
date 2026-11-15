@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// `cmux keys fill NAME --tab T --selector S` (design/settings-keys.md): the app fills a stored key
/// with `browser.page.fill`/`type` and `secret: true`. The agent cursor masks it, the answer never
/// carries the field's value back, and with `secret_hosts` the key goes only to a page on one of
/// those sites (or under one): anywhere else the call is refused with `secret_host_mismatch`
/// before any page script runs. Leo, 2026-11-15: "letting agents safely write keys and store them
/// or enter them jnto whatever".
@Suite(.timeLimit(.minutes(1))) struct BrowserPageSecretFillTests {
    final class PageEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let scripts = Mutex(0)
        /// The page's own URL (`.state`); nil answers none, so the snapshot's URL is used.
        let liveURL: String?

        init(liveURL: String? = nil) { self.liveURL = liveURL }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            if case .state = operation { return liveURL.map { ["url": .string($0)] } ?? [:] }
            scripts.withLock { $0 += 1 }
            // The fill script answers the field's new value and where it is.
            return ["value": ["value": "s3cr3t-value", "at": ["x": 10, "y": 20, "w": 200, "h": 30, "secret": false]]]
        }

        func announce(_ input: BrowserPageAgentInput, tabID: String) async {
            announced.withLock { $0.append(input) }
        }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
        var ran: Int { scripts.withLock { $0 } }
    }

    func install(url: String = "https://dashboard.example.com/settings/tokens", liveURL: String? = nil) -> (ControlRouter, PageEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let engine = PageEngine(liveURL: liveURL)
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Form", url: url)
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func fill(_ router: ControlRouter, verb: String = "fill", _ extra: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        var params: [String: JSONValue] = ["tab": "tab_0123abcd", "selector": "#key", "text": "s3cr3t-value"]
        for (key, value) in extra { params[key] = value }
        return await router.handle(ControlRequest(method: "browser.page." + verb, params: params))
    }

    @Test(arguments: ["fill", "type"])
    func aSecretFillMasksTheCursorAndNeverAnswersTheValue(verb: String) async throws {
        let (router, engine) = install()
        let result = try await fill(router, verb: verb, ["secret": true]).get()
        #expect(result["value"] == Optional<JSONValue>.none, "no value key at all")
        #expect(result["secret"] == .bool(true))
        let input = try #require(engine.inputs.last)
        #expect(input.secret == true, "the field said it shows its text, but a stored key is masked anyway")
        #expect(input.text == String(repeating: "•", count: "s3cr3t-value".count))
        #expect(engine.ran == 1)
    }

    @Test func aPlainFillStillAnswersItsValue() async throws {
        let (router, engine) = install()
        let result = try await fill(router, ["text": "cats"]).get()
        #expect(result["value"] == .string("s3cr3t-value"))
        #expect(engine.inputs.last?.secret == false)
        #expect(engine.inputs.last?.text == "cats")
    }

    @Test(arguments: [["example.com"], ["dashboard.example.com"], ["https://Example.com/", "example.org"]])
    func aSecretGoesToItsSiteOrUnderIt(hosts: [String]) async throws {
        let (router, engine) = install()
        _ = try await fill(router, ["secret": true, "secret_hosts": .array(hosts.map(JSONValue.string))]).get()
        #expect(engine.ran == 1)
    }

    @Test(arguments: ["https://example.com.evil.test/", "https://notexample.com/", "about:blank"])
    func aSecretForAnotherSiteIsRefusedBeforeAnyScriptRuns(url: String) async {
        let (router, engine) = install(url: url)
        let refused = await fill(router, ["secret": true, "secret_hosts": ["example.com"]])
        #expect(refused.failure?.code == "secret_host_mismatch")
        #expect(refused.failure?.data?["hosts"] == .array(["example.com"]))
        #expect(engine.ran == 0)
        #expect(engine.inputs.isEmpty)
    }

    @Test func thePagesOwnURLWinsOverALaggingSnapshot() async {
        // The snapshot still says example.com; the page itself redirected elsewhere.
        let (router, engine) = install(url: "https://example.com/login", liveURL: "https://phish.example/login")
        let refused = await fill(router, ["secret": true, "secret_hosts": ["example.com"]])
        #expect(refused.failure?.code == "secret_host_mismatch")
        #expect(refused.failure?.data?["host"] == .string("phish.example"))
        #expect(engine.ran == 0)
    }

    @Test func hostMatching() {
        #expect(BrowserPageService.host(of: "https://api.example.com./v1", isIn: ["example.com"]))
        #expect(BrowserPageService.host(of: "https://EXAMPLE.com", isIn: ["example.com"]))
        #expect(!BrowserPageService.host(of: "https://xexample.com", isIn: ["example.com"]))
        #expect(!BrowserPageService.host(of: nil, isIn: ["example.com"]))
        #expect(!BrowserPageService.host(of: "file:///tmp/a.html", isIn: ["example.com"]))
    }
}
