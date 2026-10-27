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

    /// A page: `state` gives its URL, the isolated origin probe its origin (`origin`; a throw when
    /// `probeFails`), other isolated scripts are the fill (answering `fill`) or the submit, and
    /// `evaluate` is an agent's `eval`. Every tab shows the same page.
    final class LoginEngine: BrowserPageEngine {
        let announced = Mutex<[BrowserPageAgentInput]>([])
        let isolatedScripts = Mutex<[String]>([])
        let agentScripts = Mutex<[String]>([])
        let page: Mutex<(url: String, origin: String)>
        let opener = Mutex(false)
        let probeFails = Mutex(false)
        let probeCount = Mutex(0)
        let fill: JSONValue
        let failure: ControlError?

        init(url: String, fill: JSONValue, failure: ControlError? = nil) {
            let origin = URL(string: url).flatMap(BrowserPageService.webOrigin) ?? "null"
            self.page = Mutex((url, origin))
            self.fill = fill
            self.failure = failure
        }

        var url: String { page.withLock { $0.url } }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            switch operation {
            case .state:
                return ["url": .string(self.url), "title": "Sign in"]
            case .evaluateIsolated(let script) where script == BrowserPageScripts.originProbe:
                probeCount.withLock { $0 += 1 }
                if probeFails.withLock({ $0 }) { throw ControlError(code: "js_error", message: "no isolated world") }
                return ["value": ["origin": .string(page.withLock { $0.origin }), "opener": .bool(opener.withLock { $0 })]]
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

        /// A navigation (every tab shows `url` now).
        func navigate(to url: String) {
            page.withLock { $0 = (url, URL(string: url).flatMap(BrowserPageService.webOrigin) ?? "null") }
        }

        var inputs: [BrowserPageAgentInput] { announced.withLock { $0 } }
        var probes: Int { probeCount.withLock { $0 } }
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

    /// Two agent tabs (`tab_0123abcd`, `tab_other`) showing the engine's page.
    func install(_ engine: LoginEngine, _ lookups: Lookups, profile: String? = BrowserPageService.agentBrowserProfileID,
                 guardsFile: URL? = nil, guards: BrowserLoginGuards? = nil, enabled: Bool = true) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        BrowserPageService(engine: engine, logins: lookups.logins, loginGuards: guards ?? BrowserLoginGuards(file: guardsFile),
                           secureStoreFillEnabled: { enabled }).install(on: router)
        var snapshot = ControlSnapshot.sample()
        for (id, surface) in [("tab_0123abcd", "12"), ("tab_other", "13")] {
            var tab = ControlTabInfo(id: id, surface: surface, kind: "browser", title: "Sign in", url: engine.url)
            tab.browserProfileID = profile
            snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        }
        router.snapshots.publish { $0 = snapshot }
        return router
    }

    func call(_ router: ControlRouter, _ params: [String: JSONValue] = [:], tab: String = "tab_0123abcd") async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = .string(tab)
        return await router.handle(ControlRequest(method: "browser.page.fill_login", params: params))
    }

    func eval(_ router: ControlRouter, tab: String = "tab_0123abcd") async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.eval",
                                           params: ["tab": .string(tab), "script": "document.querySelector('input[type=password]').value"]))
    }

    func waitFunction(_ router: ControlRouter) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: "browser.page.wait",
                                           params: ["tab": "tab_0123abcd", "function": "document.querySelector('input[type=password]').value",
                                                    "timeout_ms": 50]))
    }

    static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("login-guards-\(UUID().uuidString)").appendingPathComponent("guards.json")
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
        #expect(fill.contains(BrowserPageScripts.literal("www.example.com")) && fill.contains(BrowserPageScripts.literal("https://www.example.com"))
            && fill.contains("'https:'"))
        #expect(fill.contains(BrowserPageScripts.secretMark) && fill.contains("MutationObserver"), "a revealed password empties")
        #expect(engine.evaluated.last == BrowserPageScripts.submitLogin(host: "www.example.com", origin: "https://www.example.com"))
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

    @Test func aFilledSiteRefusesAgentScriptsInEveryTab() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = try await call(router).get()
        for tab in ["tab_0123abcd", "tab_other"] {
            guard case .failure(let error) = await eval(router, tab: tab) else { Issue.record("eval read the filled site in \(tab)"); return }
            #expect(error.code == "login_filled")
        }
        guard case .failure(let waited) = await waitFunction(router) else { Issue.record("wait ran on the filled site"); return }
        #expect(waited.code == "login_filled")
        // Another page of the site, after a navigation: still refused.
        engine.navigate(to: "https://www.example.com/feed")
        guard case .failure = await eval(router) else { Issue.record("eval ran on the filled site after a navigation"); return }
        #expect(engine.agentEvaluated.isEmpty, "no agent script reached the site")
        // Another site is fine.
        engine.navigate(to: "https://news.example.org/")
        _ = try await eval(router).get()
        #expect(engine.agentEvaluated.count == 1)
    }

    @Test func aScriptedSiteGetsNoLoginInAnyTab() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = try await eval(router, tab: "tab_other").get()
        // Another page of the site in another tab: an opener handle or a service worker could be waiting.
        engine.navigate(to: "https://www.example.com/signin")
        let answer = try await call(router).get()
        #expect(answer["filled"] == false)
        #expect(answer["reason"] == "scripted_origin")
        #expect(engine.evaluated.isEmpty, "no fill script ran")
    }

    @Test func anUnreadableOriginRefusesScriptsOnceASiteIsFilled() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        engine.probeFails.withLock { $0 = true }
        // Nothing filled yet: an unreadable page may run the agent's script.
        _ = try await eval(router).get()
        engine.probeFails.withLock { $0 = false }
        engine.navigate(to: "https://login.example.net/")
        _ = try await call(router).get()
        engine.probeFails.withLock { $0 = true }
        guard case .failure(let error) = await eval(router) else { Issue.record("an unreadable page ran a script"); return }
        #expect(error.code == "login_filled")
    }

    @Test func theMarksOutliveTheApp() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = BrowserLoginGuards(file: file)
        #expect(await first.beginScript(profile: nil, origins: ["https://scripted.test"]))
        #expect(await first.beginFill(tab: "tab_a", profile: nil, origins: ["https://filled.test"]).admission == .admitted)
        let second = BrowserLoginGuards(file: file)
        #expect(await second.beginFill(tab: "tab_a", profile: nil, origins: ["https://scripted.test"]).admission == .scripted,
                "a scripted site stays scripted")
        #expect(await !second.beginScript(profile: nil, origins: ["https://filled.test"]), "a filled site stays filled")
        #expect(await second.beginScript(profile: "default", origins: ["https://filled.test"]), "another profile is another store")
        // Through the service: a new app run with the same file refuses the eval.
        let engine = LoginEngine(url: "https://filled.test/", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved), guardsFile: file)
        guard case .failure(let error) = await eval(router) else { Issue.record("the filled site was forgotten"); return }
        #expect(error.code == "login_filled")
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

    @Test func theSettingOffFillsNothing() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let lookups = Lookups(Self.saved)
        let answer = try await call(install(engine, lookups, enabled: false)).get()
        #expect(answer["filled"] == false)
        #expect(answer["reason"] == "disabled")
        #expect(engine.evaluated.isEmpty)
        #expect(lookups.hosts.withLock { $0 }.isEmpty, "the store is not even read")
    }

    @Test func anUnreadableGuardFileRefusesEveryFillAndIsKept() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved), guardsFile: file)
        #expect(try await call(router).get()["reason"] == "guard_unreadable")
        _ = try await eval(router, tab: "tab_other").get()
        #expect(try Data(contentsOf: file) == Data("not json".utf8), "the broken file is never overwritten")
        #expect(engine.evaluated.isEmpty)
    }

    @Test func aFailedSaveRefusesFillsOnItsSitesUntilASaveSucceeds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("login-guards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A file where the guard's folder should be: every save fails.
        let blocker = folder.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let guards = BrowserLoginGuards(file: blocker.appendingPathComponent("guards.json"))
        #expect(await guards.beginScript(profile: nil, origins: ["https://a.test"]))
        #expect(await guards.beginFill(tab: "tab_x", profile: nil, origins: ["https://b.test"]).admission == .unsaved)
        // The marks stay in memory: the scripted site still refuses a fill, the filled one a script.
        #expect(await guards.beginFill(tab: "tab_x", profile: nil, origins: ["https://a.test"]).admission == .scripted)
        #expect(await !guards.beginScript(profile: nil, origins: ["https://b.test"]))
        // Saving works again: the next change saves, and fills are admitted again.
        try FileManager.default.removeItem(at: blocker)
        #expect(await guards.beginScript(profile: nil, origins: ["https://c.test"]))
        #expect(await guards.beginFill(tab: "tab_x", profile: nil, origins: ["https://d.test"]).admission == .admitted)
    }

    @Test func storageAndCookieWritesAreAgentCode() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        // A storage write marks the site: no fill there afterwards.
        _ = try await router.handle(ControlRequest(method: "browser.page.storage.set",
                                                   params: ["tab": "tab_0123abcd", "key": "k", "value": "v"])).get()
        #expect(try await call(router).get()["reason"] == "scripted_origin")
        // On a filled site, storage and cookie writes are refused.
        engine.navigate(to: "https://login.example.net/")
        _ = try await call(router).get()
        for (method, params) in [("browser.page.storage.set", ["key": "k", "value": "v"]),
                                 ("browser.page.cookies.set", ["name": "a", "value": "1"])] as [(String, [String: JSONValue])] {
            var params = params
            params["tab"] = "tab_0123abcd"
            guard case .failure(let error) = await router.handle(ControlRequest(method: method, params: params)) else {
                Issue.record("\(method) ran on the filled site")
                continue
            }
            #expect(error.code == "login_filled")
        }
    }

    @Test func aScriptedWaitReadsTheGuardOncePerPageNotPerPoll() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let router = install(engine, Lookups(Self.saved))
        _ = await router.handle(ControlRequest(method: "browser.page.wait",
                                               params: ["tab": "tab_0123abcd", "function": "false", "timeout_ms": 300]))
        #expect(engine.probes == 2, "one guard read before the wait and one after, however many polls ran")
    }

    @Test func theBrowserHostGateGuardsItsAgentCodeAndCaptures() async throws {
        let engine = LoginEngine(url: "https://www.example.com/login", fill: Self.filledBoth)
        let guards = BrowserLoginGuards(file: nil)
        let gate = BrowserAgentCodeGate(guards: guards, engine: engine)
        let router = install(engine, Lookups(Self.saved), guards: guards)
        let profile = BrowserPageService.agentBrowserProfileID
        // A host `frame.evaluate` on a site marks it, as `eval` does: no fill there.
        #expect(await gate.admit(tabID: "tab_other", url: engine.url, profile: profile) == nil)
        #expect(try await call(router).get()["reason"] == "scripted_origin")
        // A filled site refuses host code and host captures (screenshot, PDF).
        engine.navigate(to: "https://login.example.net/")
        #expect(await gate.admitCapture(tabID: "tab_other", url: engine.url, profile: profile) == nil, "nothing filled yet")
        #expect(try await call(router).get()["filled"] == true)
        #expect(await gate.admit(tabID: "tab_other", url: engine.url, profile: profile) != nil)
        #expect(await gate.admitCapture(tabID: "tab_other", url: engine.url, profile: profile) != nil)
        // A tab a page opened never gets a fill.
        await gate.openedByPage(tabID: "tab_other")
        engine.navigate(to: "https://third.example.com/")
        #expect(try await call(router, tab: "tab_other").get()["reason"] == "opened_by_page")
    }

    @Test func rawDevToolsIsRefusedInAProfileHoldingAnyFill() async throws {
        let engine = LoginEngine(url: "https://login.example.net/", fill: Self.filledBoth)
        let guards = BrowserLoginGuards(file: nil)
        let gate = BrowserAgentCodeGate(guards: guards, engine: engine)
        let router = install(engine, Lookups(Self.saved), guards: guards)
        let profile = BrowserPageService.agentBrowserProfileID
        #expect(try await call(router).get()["filled"] == true)
        // Another site, another tab: still refused, the attach and every message (raw DevTools
        // sessions reach other frames and targets).
        engine.navigate(to: "https://elsewhere.test/")
        #expect(await gate.admitRaw(tabID: "tab_other", url: engine.url, profile: profile) != nil)
        for url in ["https://elsewhere.test/", "about:blank", nil] as [String?] {
            #expect(gate.rawMessage(url: url, profile: profile) != nil, "\(url ?? "nil")")
        }
        // Another profile holds no fill: its relay runs.
        #expect(gate.rawMessage(url: "https://elsewhere.test/", profile: "default") == nil)
        #expect(await gate.admitRaw(tabID: "tab_person", url: "https://elsewhere.test/", profile: "default") == nil)
    }

    @Test func anAttachedRawRelayHoldsBackFillsInItsProfile() async throws {
        let engine = LoginEngine(url: "https://start.example.com/", fill: Self.filledBoth)
        let guards = BrowserLoginGuards(file: nil)
        let gate = BrowserAgentCodeGate(guards: guards, engine: engine)
        let router = install(engine, Lookups(Self.saved), guards: guards)
        let profile = BrowserPageService.agentBrowserProfileID
        #expect(await gate.admitRaw(tabID: "tab_other", url: engine.url, profile: profile) == nil)
        engine.navigate(to: "https://login.example.net/")
        #expect(try await call(router).get()["reason"] == "raw_devtools_attached")
        // Detached: the other tab fills; the relayed tab itself never does.
        gate.rawEnded(tabID: "tab_other")
        #expect(try await call(router, tab: "tab_other").get()["reason"] == "scripted_origin")
        #expect(try await call(router).get()["filled"] == true)
    }

    @Test func aRawMessageMarksItsSiteAtOnce() async throws {
        let engine = LoginEngine(url: "https://start.example.com/", fill: Self.filledBoth)
        let guards = BrowserLoginGuards(file: nil)
        let gate = BrowserAgentCodeGate(guards: guards, engine: engine)
        let router = install(engine, Lookups(Self.saved), guards: guards)
        let profile = BrowserPageService.agentBrowserProfileID
        #expect(await gate.admitRaw(tabID: "tab_other", url: engine.url, profile: profile) == nil)
        #expect(gate.rawMessage(url: "https://site.example.com/a", profile: profile) == nil)
        #expect(!guards.noteRawSite(profile: profile, origin: "https://site.example.com"), "marked by the message itself")
        gate.rawEnded(tabID: "tab_other")
        engine.navigate(to: "https://site.example.com/login")
        #expect(try await call(router).get()["reason"] == "scripted_origin")
    }

    @Test func aFailedFillRemovesOnlyTheMarksItAdded() async throws {
        let guards = BrowserLoginGuards(file: nil)
        let first = await guards.beginFill(tab: "tab_a", profile: nil, origins: ["https://x.test"])
        #expect(first.admission == .admitted)
        #expect(first.added == [BrowserLoginGuards.key(profile: nil, origin: "https://x.test")])
        // A second fill on the same site adds nothing; its failure removes nothing.
        let second = await guards.beginFill(tab: "tab_b", profile: nil, origins: ["https://x.test"])
        #expect(second.admission == .admitted)
        #expect(second.added.isEmpty)
        await guards.forgetFill(second.added)
        #expect(await !guards.beginScript(profile: nil, origins: ["https://x.test"]), "the first fill's mark stays")
        // The first fill's own failure removes its mark.
        await guards.forgetFill(first.added)
        #expect(await guards.beginScript(profile: nil, origins: ["https://x.test"]))
    }

    @Test func aScreenshotOfAFilledSiteIsRefused() async throws {
        let engine = LoginEngine(url: "https://login.example.net/", fill: Self.filledBoth)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        BrowserPageService(engine: engine, leases: BrowserTabLeases(), allowsUnsafeCapture: true, logins: Lookups(Self.saved).logins,
                           loginGuards: BrowserLoginGuards(file: nil), secureStoreFillEnabled: { true }).install(on: router)
        var snapshot = ControlSnapshot.sample()
        var tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "Sign in", url: engine.url)
        tab.browserProfileID = BrowserPageService.agentBrowserProfileID
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        _ = try await call(router).get()
        guard case .failure(let error) = await router.handle(ControlRequest(method: "browser.page.screenshot", params: ["tab": "tab_0123abcd"])) else {
            Issue.record("the filled site was captured")
            return
        }
        #expect(error.code == "login_filled")
    }

    @Test func aSavedLoginNeverPrintsItsSecrets() {
        #expect(Self.holdsNoSecret(Self.saved))
        #expect(Self.holdsNoSecret(String(reflecting: Self.saved)))
        var dumped = ""
        dump(Self.saved, to: &dumped)
        #expect(Self.holdsNoSecret(dumped))
    }
}
