import CmuxNextBrowser
import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowserAutomation

/// The driver protocol on a real WKWebView: params are checked, unknown
/// methods are unsupported, navigation waits for the load state it names,
/// and frame.evaluate runs in the page, agent and host worlds, which do not
/// share globals.
@MainActor
@Suite(.serialized) struct DriverCallTests {
    final class FakeProvider: AutomationTabProvider {
        var tabs: [WebKitTab] = []
        let engine = WebKitEngine(profileStore: WebKitProfileStore(factory: NonPersistentStores()), applicationNameForUserAgent: nil)

        func automationTabs(all: Bool) -> [AutomationTab] {
            tabs.map { AutomationTab(tab: $0, windowID: "w1", isActive: $0 === tabs.first) }
        }

        func openAutomationTab(url: URL?) async throws -> WebKitTab {
            let tab = engine.makeWebKitTab(BrowserTabConfiguration(profile: .default))
            tab.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            tabs.append(tab)
            return tab
        }

        func closeAutomationTab(_ id: BrowserTabID) {
            tabs.removeAll { $0.id == id }
        }

        func activateAutomationTab(_ id: BrowserTabID) {}

        /// Tabs a session's end closed (`tabs.close {reason: session_end}`).
        var sessionEndCloses: [String] = []
        func endSessionTab(_ id: String) { sessionEndCloses.append(id) }
    }

    struct NonPersistentStores: WebsiteDataStoreFactory {
        func makeStore(identifier: UUID) -> WKWebsiteDataStore { .nonPersistent() }
        func removeStore(identifier: UUID) async throws {}
    }

    static let page = "data:text/html,<title>Fixture</title><input id=f value=x><script>window.pageOnly = 42</script>"

    @Test func paramsAreTypedAndUnknownMethodsUnsupported() async throws {
        let driver = WebKitDriver(provider: FakeProvider())
        await #expect(throws: DriverError(.unsupported, "Unsupported driver method tab.teleport")) {
            try await driver.call(method: "tab.teleport", params: .object([:]))
        }
        let error = await #expect(throws: DriverError.self) {
            try await driver.call(method: "tab.info", params: .object(["targetId": .number(3)]))
        }
        #expect(error?.code == .invalid && error?.message == "tab.info: targetId: expected a string, got a number")
        let missing = await #expect(throws: DriverError.self) {
            try await driver.call(method: "tab.info", params: .object(["targetId": .string("nope")]))
        }
        #expect(missing?.code == .notFound)
    }

    @Test func openNavigateInfoAndEvaluateInEachWorld() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider, agentBundle: "globalThis[Symbol.for(\"cmux.browserRepl.agent\")] = { ping: () => \"pong\" };")
        let opened = try await driver.call(method: "tabs.open", params: .object([:]))
        guard case .object(let fields) = opened, case .string(let id)? = fields["targetId"] else {
            Issue.record("tabs.open returned \(opened)")
            return
        }
        let nav = try await driver.call(method: "tab.navigate", params: .object([
            "targetId": .string(id), "url": .string(Self.page), "waitUntil": .string("load"), "timeoutMs": .number(15000),
        ]))
        guard case .object(let navFields) = nav else { Issue.record("tab.navigate returned \(nav)"); return }
        #expect(navFields["url"]?.stringValue?.hasPrefix("data:text/html") == true)

        let info = try await driver.call(method: "tab.info", params: .object(["targetId": .string(id)]))
        guard case .object(let infoFields) = info else { Issue.record("tab.info returned \(info)"); return }
        #expect(infoFields["title"] == .string("Fixture"))
        #expect(infoFields["loadState"] == .string("load"))

        func evaluate(_ world: String, _ source: String) async throws -> DriverJSON {
            try await driver.call(method: "frame.evaluate", params: .object([
                "targetId": .string(id), "world": .string(world), "source": .string(source), "args": .array([.number(1)]),
            ]))
        }
        #expect(try await evaluate("page", "(n) => window.pageOnly + n") == .number(43))
        #expect(try await evaluate("agent", "(n) => typeof window.pageOnly") == .string("undefined"))
        #expect(try await evaluate("agent", "(n) => globalThis[Symbol.for('cmux.browserRepl.agent')].ping()") == .string("pong"))
        #expect(try await evaluate("host", "(n) => [typeof window.pageOnly, typeof globalThis[Symbol.for('cmux.browserRepl.agent')]]")
            == .array([.string("undefined"), .string("undefined")]))
        #expect(try await evaluate("host", "() => document.getElementById('f').value") == .string("x"))

        let thrown = await #expect(throws: DriverError.self) { try await evaluate("page", "() => { throw new TypeError('boom') }") }
        #expect(thrown?.code == .evaluation)

        let frames = try await driver.call(method: "frames.list", params: .object(["targetId": .string(id)]))
        guard case .array(let list) = frames, case .object(let main)? = list.first else { Issue.record("frames.list returned \(frames)"); return }
        #expect(main["parentFrameId"] == .null)
        _ = try await driver.call(method: "tabs.close", params: .object(["targetId": .string(id)]))
        #expect(provider.tabs.isEmpty)
    }

    @Test func navigationTimesOutWithTheProtocolCode() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let tab = try await provider.openAutomationTab(url: nil)
        // A page whose load never ends (an image that never answers) stays before "load".
        let error = await #expect(throws: DriverError.self) {
            try await driver.call(method: "tab.navigate", params: .object([
                "targetId": .string(tab.id.rawValue), "url": .string("http://10.255.255.1/never"),
                "waitUntil": .string("load"), "timeoutMs": .number(300),
            ]))
        }
        #expect(error?.code == .timeout)
    }

    /// A session's end closes the tabs it created through the app's store close (both engines),
    /// marked so closed history leaves them out; the driver never looks for a WebKit page first.
    @Test func aSessionEndCloseGoesToTheAppForEitherEngine() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider)
        let opened = try await driver.call(method: "tabs.open", params: .object([:]))
        guard case .object(let fields) = opened, case .string(let webKit)? = fields["targetId"] else {
            Issue.record("tabs.open returned \(opened)")
            return
        }
        _ = try await driver.call(method: "tabs.close",
                                  params: .object(["targetId": .string(webKit), "reason": .string("session_end")]))
        // A Chromium tab has no WebKit page here: the close still reaches the app.
        _ = try await driver.call(method: "tabs.close",
                                  params: .object(["targetId": .string("tab_chromium"), "reason": .string("session_end")]))
        #expect(provider.sessionEndCloses == [webKit, "tab_chromium"])
    }
}
