@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.fill_login` (cmux https://github.com/manaflow-ai/cmux/issues/25830): the app fills
/// the person's Secure Store login into the agent's page; the agent's answer, its cursor and any
/// error never carry the username or the password, and no agent script reaches the filled page
/// (``BrowserLoginGuards``).
@Suite(.timeLimit(.minutes(1))) struct BrowserPageFillLoginTests {
    static let username = "ada@example.com"
    static let password = "hunter2-SECRET-pw"

    /// A page: `state` gives its URL, the isolated document probe its current document, other
    /// isolated scripts are the fill (answering `fill`) or the submit, and `evaluate` is an
    /// agent's `eval`.
    final class LoginEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let isolatedScripts = Mutex<[String]>([])
        let agentScripts = Mutex<[String]>([])
        let document = Mutex("1000.5")
        let opener = Mutex(false)
        let url: String
        let fill: JSONValue
        let failure: ControlError?

        init(url: String, fill: JSONValue, failure: ControlError? = nil) {
            self.url = url
            self.fill = fill
            self.failure = failure
        }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            switch operation {
            case .state:
                return ["url": .string(self.url), "title": "Sign in"]
            case .evaluateIsolated(let script) where script == BrowserPageScripts.documentProbe:
                return ["value": ["document": .string(document.withLock { $0 }), "opener": .bool(opener.withLock { $0 })]]
            case .evaluateIsolated(let script):
                isolatedScripts.withLock { $0.append(script) }
                if let failure { throw failure }
                let answer: JSONValue = script.contains("requestSubmit") ? ["value": true] : fill
                return ["value": answer]
            case .evaluate(let script):
                agentScripts.withLock { $0.append(script) }
                return ["value": 1]
            default:
                return [:]
            }
        }

        func announce(_ input: BrowserPageAgentInput, tabID: String) async {
            announced.withLock { $0.append(input) }
        }

        /// A navigation: a new document.
        func navigate(to document: String) { self.document.withLock { $0 = document } }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
        var evaluated: [String] { isolatedScripts.withLock { $0 } }
        var agentEvaluated: [String] { agentScripts.withLock { $0 } }
    }

    final class Lookups: Sendable {
        let hosts = Mutex<[String]>([])
        let login: BrowserPageLogin?

        init(_ login: BrowserPageLogin?) { self.login = login }

        var logins: BrowserPageLogins {
            { [self] host in
                hosts.withLock { $0.append(host) }
                return login
            }
        }
    }

    static let saved = BrowserPageLogin(site: "example.com", username: username, password: password)
    static let at: JSONValue = ["x": 10, "y": 20, "w": 200, "h": 30, "secret": false]
    static let filledBoth: JSONValue = ["value": ["username": true, "password": true], "at": at]

    func install(_ engine: LoginEngine, _ lookups: Lookups, profile: String? = BrowserPageService.agentBrowserProfileID) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        BrowserPageService(engine: engine, logins: lookups.logins).install(on: router)
        var snapshot = ControlSnapshot.sample()
        var tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Sign in", url: engine.url)
        tab.browserProfileID = profile
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return router
    }

    func call(_ router: ControlRouter, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: "browser.page.fill_login", params: params))
    }

    func eval(_ router: ControlRouter) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.eval",
                                           params: ["tab": "tab_0123abcd", "script": "document.querySelector('input[type=password]').value"]))
    }

    func waitFunction(_ router: ControlRouter) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.wait",
                                           params: ["tab": "tab_0123abcd", "function": "document.querySelector('input[type=password]').value",
                                                    "timeout_ms": 50]))
    }

    /// Neither secret appears anywhere in `value`'s text.
    static func holdsNoSecret(_ value: some Any) -> Bool {
        let text = String(describing: value)
        return !text.contains(username) && !text.contains(password)
    }

    @Test func withNoSavedLoginItFillsNothing() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: [:])
        let lookups = Lookups(nil)
        let answer = try await call(install(engine, lookups)).get()
        #expect(answer["filled"] == false)
        #expect(answer["site"] == .null)
        #expect(answer["reason"] == "no_saved_login")
        #expect(engine.evaluated.isEmpty)
        #expect(engine.inputs.isEmpty)
        #expect(lookups.hosts.withLock { $0 } == ["www.example.com"], "the page's current host is looked up")
    }

    @Test func itFillsBothFieldsSubmitsAndAnswersOnlyWhatItFilled() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let answer = try await call(install(engine, Lookups(Self.saved)), ["submit": true, "agent": "Chief"]).get()
        #expect(answer["filled"] == true)
        #expect(answer["site"] == "example.com")
        #expect(answer["username_filled"] == true)
        #expect(answer["password_filled"] == true)
        #expect(answer["submitted"] == true)
        #expect(Self.holdsNoSecret(answer))
        // The values ride only in the fill script (isolated world), which checks the document,
        // host and https first; the submit is a second script that checks them again.
        #expect(engine.evaluated.count == 2)
        let fill = try #require(engine.evaluated.first)
        #expect(fill.contains("www.example.com") && fill.contains("1000.5") && fill.contains("https:"))
        #expect(engine.evaluated.last == BrowserPageScripts.submitLogin(host: "www.example.com", document: "1000.5"))
        #expect(Self.holdsNoSecret(engine.evaluated.last ?? ""))
        #expect(engine.agentEvaluated.isEmpty, "nothing runs in the page's world")
        // The agent cursor draws a secret fill with no text, even when the page said the field shows its text.
        let input = try #require(engine.inputs.first)
        #expect(input.secret)
        #expect(input.text == nil)
        #expect(input.agent == "Chief")
        #expect(Self.holdsNoSecret(input))
    }

    @Test func aTwoStepLoginFillsTheUsernameAlone() async throws {
        let engine = LoginEngine(url: "https://accounts.example.com/signin",
                                 fill: ["value": ["username": true, "password": false], "at": Self.at])
        let answer = try await call(install(engine, Lookups(Self.saved))).get()
        #expect(answer["filled"] == true)
        #expect(answer["username_filled"] == true)
        #expect(answer["password_filled"] == false)
        #expect(answer["submitted"] == false)
        #expect(engine.evaluated.count == 1, "no submit unless asked")
    }

    @Test func aPageWithNoLoginFieldSaysSo() async throws {
        let engine = LoginEngine(url: "https://www.example.com/",
                                 fill: ["value": ["username": false, "password": false, "reason": "no_login_field"]])
        let answer = try await call(install(engine, Lookups(Self.saved)), ["submit": true]).get()
        #expect(answer["filled"] == false)
        #expect(answer["reason"] == "no_login_field")
        #expect(engine.evaluated.count == 1, "nothing to submit")
        #expect(engine.inputs.isEmpty)
    }

    @Test func aLoginIsNeverFilledIntoAPlainHttpPage() async throws {
        let engine = LoginEngine(url: "http://www.example.com/login", fill: [:])
        let answer = try await call(install(engine, Lookups(Self.saved))).get()
        #expect(answer["filled"] == false)
        #expect(answer["reason"] == "not_https")
        #expect(engine.evaluated.isEmpty)
    }

    @Test func aPageErrorComesBackWithoutItsMessage() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: [:],
                                 failure: ControlError(code: "js_error", message: "SyntaxError near '\(Self.password)'"))
        let result = await call(install(engine, Lookups(Self.saved)))
        guard case .failure(let error) = result else { Issue.record("expected an error"); return }
        #expect(error.code == "js_error")
        #expect(Self.holdsNoSecret(error.message))
    }

    @Test func itIsALeasedWriteVerb() async throws {
        #expect(!BrowserPageService.rightReadVerbs.contains("browser.page.fill_login"))
        #expect(!BrowserPageService.leaseFreeMethods.contains("browser.page.fill_login"))
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = try await call(router, ["agent": "Muse"]).get()
        let refused = await call(router, ["agent": "Chief"])
        guard case .failure(let error) = refused else { Issue.record("expected lease_held"); return }
        #expect(error.code == "lease_held")
    }

    @Test func anEvalOrScriptedWaitOnTheFilledPageIsRefused() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = try await call(router).get()
        guard case .failure(let error) = await eval(router) else { Issue.record("eval read the filled page"); return }
        #expect(error.code == "login_filled")
        guard case .failure(let waited) = await waitFunction(router) else { Issue.record("wait ran on the filled page"); return }
        #expect(waited.code == "login_filled")
        #expect(engine.agentEvaluated.isEmpty, "no agent script reached the page")
    }

    @Test func aPageAnAgentScriptedGetsNoLogin() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = try await eval(router).get()
        let answer = try await call(router).get()
        #expect(answer["filled"] == false)
        #expect(answer["reason"] == "scripted_page")
        #expect(engine.evaluated.isEmpty, "no fill script ran")
    }

    @Test func aFreshDocumentAfterNavigationIsCleanAgain() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        // Scripted, then a new document: the fill is allowed there.
        _ = try await eval(router).get()
        engine.navigate(to: "2000.25")
        #expect(try await call(router).get()["filled"] == true)
        // Filled, then a new document: the agent's scripts run again.
        engine.navigate(to: "3000.75")
        #expect(try await eval(router).get()["tab"] == "tab_0123abcd")
    }

    @Test func thePersonsProfileTabNeverGetsALogin() async throws {
        for profile in ["default", "5b1d0000-0000-4000-8000-000000000001"] {
            let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
            let lookups = Lookups(Self.saved)
            let answer = try await call(install(engine, lookups, profile: profile)).get()
            #expect(answer["filled"] == false)
            #expect(answer["reason"] == "not_agent_tab")
            #expect(engine.evaluated.isEmpty)
            #expect(lookups.hosts.withLock { $0 }.isEmpty, "the store is not even read")
        }
    }

    @Test func aWindowAnotherPageOpenedGetsNoLogin() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        engine.opener.withLock { $0 = true }
        let answer = try await call(install(engine, Lookups(Self.saved))).get()
        #expect(answer["reason"] == "opened_by_page")
        #expect(engine.evaluated.isEmpty)
    }

    @Test func aSavedLoginNeverPrintsItsSecrets() {
        #expect(Self.holdsNoSecret(Self.saved))
        #expect(Self.holdsNoSecret(String(reflecting: Self.saved)))
        var dumped = ""
        dump(Self.saved, to: &dumped)
        #expect(Self.holdsNoSecret(dumped))
    }
}
