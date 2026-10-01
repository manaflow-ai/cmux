@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Synchronization
import Testing

/// `browser.page.cookies.*` and `browser.page.storage.*` follow the old
/// `cmux browser cookies|storage`: listing filters by name, domain substring
/// and path; clearing takes exactly one of `all` or a scope and matches a
/// url as a request would; setting takes the domain from the url, the
/// domain, or the tab's page. Before, app browser tabs had neither.
@Suite(.timeLimit(.minutes(1))) struct BrowserPageCookiesTests {
    final class CookieEngine: BrowserPageEngine {
        let calls = Mutex<[BrowserPageOperation]>([])
        let stored: [BrowserPageCookie]

        init(_ stored: [BrowserPageCookie]) { self.stored = stored }

        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue {
            calls.withLock { $0.append(operation) }
            switch operation {
            case .cookies(.list): return ["cookies": .array(stored.map(\.json))]
            case .evaluate: return ["value": ["value": ["key": "theme", "value": "dark"]]]
            default: return [:]
            }
        }

        var operations: [BrowserPageOperation] { calls.withLock { $0 } }
    }

    static let session = BrowserPageCookie(name: "sid", value: "1", domain: "app.example.com", path: "/", secure: true, httpOnly: true)
    static let shared = BrowserPageCookie(name: "pref", value: "a", domain: ".example.com", path: "/")
    static let admin = BrowserPageCookie(name: "sid", value: "2", domain: "example.com", path: "/admin")
    static let other = BrowserPageCookie(name: "sid", value: "3", domain: "other.test", path: "/", expires: 1)

    func install() -> (ControlRouter, CookieEngine) {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let engine = CookieEngine([Self.session, Self.shared, Self.admin, Self.other])
        BrowserPageService(engine: engine).install(on: router)
        var snapshot = ControlSnapshot.sample()
        let tab = ControlTabInfo(id: "tab_0123abcd", surface: "12", kind: "browser", title: "App", url: "https://app.example.com/home")
        snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        router.snapshots.publish { $0 = snapshot }
        return (router, engine)
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
        var params = params
        params["tab"] = "tab_0123abcd"
        return await router.handle(ControlRequest(method: method, params: params))
    }

    func names(_ result: JSONValue) -> [String] {
        guard case .array(let cookies)? = result["cookies"] else { return [] }
        return cookies.compactMap { "\($0["name"]?.stringValue ?? "")@\($0["domain"]?.stringValue ?? "")" }
    }

    func deleted(_ engine: CookieEngine) -> [BrowserPageCookie] {
        engine.operations.flatMap { operation -> [BrowserPageCookie] in
            if case .cookies(.delete(let cookies)) = operation { return cookies }
            return []
        }
    }

    @Test func listsWithTheOldFilters() async throws {
        let (router, _) = install()
        let all = try await call(router, "browser.page.cookies.get").get()
        #expect(names(all).count == 4)
        let sid = try await call(router, "browser.page.cookies.get", ["name": "sid", "domain": "example"]).get()
        #expect(names(sid) == ["sid@app.example.com", "sid@example.com"])
        let admin = try await call(router, "browser.page.cookies.get", ["path": "/admin"]).get()
        #expect(names(admin) == ["sid@example.com"])
        if case .array(let cookies)? = all["cookies"] {
            // The old app's keys: camelCase except session_only.
            #expect(cookies[0]["httpOnly"] == true)
            #expect(cookies[0]["session_only"] == true)
            #expect(cookies[1]["hostOnly"] == false)
        }
    }

    @Test func clearsWhatARequestToTheURLWouldCarry() async throws {
        let (router, engine) = install()
        let result = try await call(router, "browser.page.cookies.clear", ["url": "https://app.example.com/settings"]).get()
        // sid@app.example.com (host-only, secure) and .example.com; not /admin, not other.test.
        #expect(result["cleared"] == 2)
        #expect(Set(deleted(engine)) == [Self.session, Self.shared])
    }

    @Test func aSecureCookieIsNotClearedForHTTPAndAnExpiredOneNever() async throws {
        let (router, engine) = install()
        _ = try await call(router, "browser.page.cookies.clear", ["url": "http://app.example.com/"]).get()
        #expect(deleted(engine) == [Self.shared])
        let none = try await call(router, "browser.page.cookies.clear", ["url": "https://other.test/"]).get()
        #expect(none["cleared"] == 0)
    }

    @Test func clearsADomainAndItsSubdomains() async throws {
        let (router, engine) = install()
        let result = try await call(router, "browser.page.cookies.clear", ["domain": ".Example.com"]).get()
        #expect(result["cleared"] == 3)
        #expect(!deleted(engine).contains(Self.other))
    }

    @Test func aClearFilterIsRefusedRatherThanIgnored() async throws {
        let (router, engine) = install()
        let wrong = await call(router, "browser.page.cookies.clear", ["domain": "example.com", "path": 1])
        #expect(wrong.failure?.code == "invalid_params")
        #expect(wrong.failure?.data?["param"] == "path")
        let noHost = await call(router, "browser.page.cookies.clear", ["url": "example.com"])
        #expect(noHost.failure?.data?["param"] == "url")
        #expect(engine.operations.isEmpty)
        // value narrows the clear instead of being dropped.
        let one = try await call(router, "browser.page.cookies.clear", ["name": "sid", "value": "2"]).get()
        #expect(one["cleared"] == 1)
        #expect(deleted(engine) == [Self.admin])
    }

    @Test func clearTakesExactlyOneOfAllOrAScope() async throws {
        let (router, engine) = install()
        #expect(await call(router, "browser.page.cookies.clear").failure?.code == "invalid_params")
        #expect(await call(router, "browser.page.cookies.clear", ["all": true, "name": "sid"]).failure?.code == "invalid_params")
        #expect(engine.operations.isEmpty)
        let all = try await call(router, "browser.page.cookies.clear", ["all": true]).get()
        #expect(all["cleared"] == 4)
    }

    @Test func setTakesItsDomainFromTheURLTheDomainOrThePage() async throws {
        let (router, engine) = install()
        _ = try await call(router, "browser.page.cookies.set", ["name": "a", "value": "1", "url": "https://docs.example.com/x"]).get()
        _ = try await call(router, "browser.page.cookies.set", ["name": "b", "value": "2", "domain": ".example.com", "secure": true]).get()
        let fromPage = try await call(router, "browser.page.cookies.set", ["cookies": [["name": "c", "value": "3", "http_only": true, "expires": 1_900_000_000]]]).get()
        #expect(fromPage["set"] == 1)
        let set = engine.operations.flatMap { operation -> [BrowserPageCookie] in
            if case .cookies(.set(let cookies)) = operation { return cookies }
            return []
        }
        #expect(set == [
            BrowserPageCookie(name: "a", value: "1", domain: "docs.example.com"),
            BrowserPageCookie(name: "b", value: "2", domain: ".example.com", secure: true),
            BrowserPageCookie(name: "c", value: "3", domain: "app.example.com", expires: 1_900_000_000, httpOnly: true),
        ])
        #expect(await call(router, "browser.page.cookies.set", ["name": "d"]).failure?.code == "invalid_params")
        #expect(await call(router, "browser.page.cookies.set", ["name": "d", "value": "a;b"]).failure?.code == "invalid_params")
    }

    @Test func aDomainWinsOverTheURLsHost() async throws {
        let (router, engine) = install()
        _ = try await call(router, "browser.page.cookies.set",
                           ["name": "a", "value": "1", "url": "https://app.example.com/", "domain": ".example.com"]).get()
        #expect(engine.operations == [.cookies(.set([BrowserPageCookie(name: "a", value: "1", domain: ".example.com")]))])
    }

    @Test func storageRunsInThePageAndReportsItsArea() async throws {
        let (router, engine) = install()
        let got = try await call(router, "browser.page.storage.get", ["type": "session", "key": "theme"]).get()
        #expect(got["type"] == "session")
        #expect(got["value"] == "dark")
        #expect(got["key"] == "theme")
        _ = try await call(router, "browser.page.storage.set", ["key": "theme", "value": "light"]).get()
        _ = try await call(router, "browser.page.storage.clear").get()
        let scripts = engine.operations.compactMap { operation -> String? in
            if case .evaluate(let script) = operation { return script }
            return nil
        }
        #expect(scripts.count == 3)
        #expect(scripts[0].contains("window.sessionStorage") && scripts[0].contains("getItem(\"theme\")"))
        #expect(scripts[1].contains("window.localStorage") && scripts[1].contains("setItem(\"theme\", \"light\")"))
        #expect(scripts[2].contains("st.clear()"))
        #expect(await call(router, "browser.page.storage.set", ["value": "x"]).failure?.code == "invalid_params")
        #expect(await call(router, "browser.page.storage.set", ["key": "k"]).failure?.code == "invalid_params")
        #expect(await call(router, "browser.page.storage.clear", ["type": "cookies"]).failure?.code == "invalid_params")
    }

    @Test func storageReadsTheOldParamsToo() async throws {
        let (router, engine) = install()
        let got = try await call(router, "browser.page.storage.clear", ["storage": " Session "]).get()
        #expect(got["type"] == "session")
        _ = try await call(router, "browser.page.storage.set", ["key": "n", "value": 3]).get()
        if case .evaluate(let script)? = engine.operations.last {
            #expect(script.contains("setItem(\"n\", \"3\")"))
        } else {
            Issue.record("expected a storage script")
        }
    }
}
