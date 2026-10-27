@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// `browser.page.fill_login` (cmux https://github.com/manaflow-ai/cmux/issues/25830): the app fills
/// the person's Secure Store login into the agent's page; the agent's answer, its cursor and any
/// error never carry the username or the password.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageFillLoginTests {
    static let username = "ada@example.com"
    static let password = "hunter2-SECRET-pw"

    final class LoginEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let scripts = Mutex<[String]>([])
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
            case .evaluate(let script):
                scripts.withLock { $0.append(script) }
                if let failure { throw failure }
                let answer: JSONValue = script == BrowserPageScripts.submitLogin ? ["value": true] : fill
                return ["value": answer]
            default:
                return [:]
            }
        }

        func announce(_ input: BrowserPageAgentInput, tabID: String) async {
            announced.withLock { $0.append(input) }
        }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
        var evaluated: [String] { scripts.withLock { $0 } }
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

    func install(_ engine: LoginEngine, _ lookups: Lookups) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        BrowserPageService(engine: engine, logins: lookups.logins).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Sign in", url: engine.url)
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return router
    }

    func call(_ router: ControlRouter, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: "browser.page.fill_login", params: params))
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
        let engine = LoginEngine(url: "https://www.example.com/login",
                                 fill: ["value": ["username": true, "password": true], "at": Self.at])
        let answer = try await call(install(engine, Lookups(Self.saved)), ["submit": true, "agent": "Chief"]).get()
        #expect(answer["filled"] == true)
        #expect(answer["site"] == "example.com")
        #expect(answer["username_filled"] == true)
        #expect(answer["password_filled"] == true)
        #expect(answer["submitted"] == true)
        #expect(Self.holdsNoSecret(answer))
        // The values ride only in the fill script, which checks the host first; the submit is a second script.
        #expect(engine.evaluated.count == 2)
        #expect(engine.evaluated.first?.contains("www.example.com") == true)
        #expect(engine.evaluated.last == BrowserPageScripts.submitLogin)
        #expect(Self.holdsNoSecret(BrowserPageScripts.submitLogin))
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
        let engine = LoginEngine(url: "https://www.example.com/login",
                                 fill: ["value": ["username": true, "password": true], "at": Self.at])
        let router = install(engine, Lookups(Self.saved))
        _ = try await call(router, ["agent": "Muse"]).get()
        let refused = await call(router, ["agent": "Chief"])
        guard case .failure(let error) = refused else { Issue.record("expected lease_held"); return }
        #expect(error.code == "lease_held")
    }

    @Test func aSavedLoginNeverPrintsItsSecrets() {
        #expect(Self.holdsNoSecret(Self.saved))
        #expect(Self.holdsNoSecret(String(reflecting: Self.saved)))
        var dumped = ""
        dump(Self.saved, to: &dumped)
        #expect(Self.holdsNoSecret(dumped))
    }
}
