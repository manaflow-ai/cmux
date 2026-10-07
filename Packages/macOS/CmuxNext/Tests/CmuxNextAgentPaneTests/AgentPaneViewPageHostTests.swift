import AppKit
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The agent pane view on the shared page host (agent pane move P2b, the `agent.pageHost`
/// tunable): the same view the app and the new tab spare pool use, with the page at
/// `cmux-page://cmux.agent/` and every host push sent as an event instead of a script.
@MainActor
@Suite struct AgentPaneViewPageHostTests {
    private func pageView() throws -> (AgentPaneView, [String]) {
        let index = try #require(AgentPaneView.bundledPage)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(index), pageHost: true))
        return (view, [])
    }

    /// Subscribes to the host events through the page's router and returns what the page receives.
    private func subscribe(_ page: PageWebView) async -> () -> [JSONValue] {
        var received: [JSONValue] = []
        page.router.send = { envelope in
            if envelope["t"]?.stringValue == "ev", let data = envelope["data"] { received.append(data) }
        }
        _ = await page.router.handle(["t": "sub", "id": 1, "stream": .string(AgentPageProvider.hostEvents)])
        for _ in 0..<5 { await Task.yield() }
        return { received }
    }

    @Test func thePageLoadsOnTheSharedPageHost() throws {
        let (view, _) = try pageView()
        defer { view.close() }
        let page = try #require(view.page)
        #expect(page.descriptor == .agent)
        #expect(view.webView === page.webKitView)
    }

    @Test func aDevServerPageStaysOnTheOldHost() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()),
                                              source: .devServer(URL(string: "http://127.0.0.1:5173/")!), pageHost: true))
        defer { view.close() }
        #expect(view.page == nil)
    }

    /// A new page subscriber gets the theme, shortcuts, preview state and the edited-files card's
    /// settings, as the old host pushed them after each load.
    @Test func aSubscribedPageGetsTheCurrentState() async throws {
        let (view, _) = try pageView()
        defer { view.close() }
        view.previewFeatures = true
        var editedFiles = AgentPaneEditedFilesSetting()
        editedFiles.show = "collapsed"
        view.editedFiles = editedFiles
        let received = await subscribe(try #require(view.page))
        // A theme change (the view joining a scope) may push the theme again; that is harmless.
        let kinds = received().compactMap { $0["kind"]?.stringValue }
        #expect(kinds.first == "theme")
        #expect(Set(kinds) == ["theme", "shortcuts", "preview", "editedFiles"])
        #expect(received().first { $0["kind"] == "preview" }?["value"] == .bool(true))
        #expect(received().first { $0["kind"] == "editedFiles" }?["value"] == ["show": "collapsed", "maxRows": 5, "scope": "turn"])
    }

    /// Commands, focus and links reach the page as events; no script runs.
    @Test func hostPushesAreEventsNotScripts() async throws {
        let (view, _) = try pageView()
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        let received = await subscribe(try #require(view.page))
        let before = received().count
        view.showContinueIn()
        view.runPermissionAction("permissionDeny")
        view.runPermissionAction("notAPermissionAction")
        view.focusLocation()
        _ = await view.model.respond(to: .ready)
        view.revealTurn("t-9")
        let events = received().dropFirst(before).map { "\($0["kind"]?.stringValue ?? ""):\($0["value"]?.stringValue ?? "")" }
        #expect(events == ["command:continueIn", "command:permissionDeny", "focusLocation:", "revealTurn:t-9"])
        #expect(scripts.isEmpty)
    }

    /// The user's registry.js runs through evaluateJavaScript, as on the old host: the page's CSP
    /// (script-src 'self') refuses a script element the page makes, and a script the host evaluates
    /// is not subject to it. The style and layout still arrive as an event. A new subscriber (the
    /// page loading again) runs the registry again.
    @Test func theRegistryRunsAsAHostScriptNotAPageEvent() async throws {
        let (view, _) = try pageView()
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        let page = try #require(view.page)
        let received = await subscribe(page)
        let before = received().count
        view.customization = AgentPaneCustomization(themeCSS: "a{}", registryJS: "window.registered = 1;")
        let registry = "(function () {\nwindow.registered = 1;\n})();"
        #expect(scripts == [registry])
        #expect(received().dropFirst(before).compactMap { $0["kind"]?.stringValue } == ["customization"])
        scripts.removeAll()
        let again = await subscribe(page)
        #expect(scripts == [registry])
        #expect(!again().contains { $0["kind"] == "registry" })
    }

    /// Loopback preview frames stay allowed and clicked web links open outside, as on the old host.
    @Test func navigationKeepsTheOldHostsRules() throws {
        let (view, _) = try pageView()
        defer { view.close() }
        let hook = try #require(view.page?.onNavigate)
        #expect(hook(PageNavigation(url: URL(string: "http://127.0.0.1:3000/")!, userClicked: false, mainFrame: false)) == .allow)
        #expect(hook(PageNavigation(url: URL(string: "https://example.com/")!, userClicked: true, mainFrame: true)) == .openExternal)
        #expect(hook(PageNavigation(url: URL(string: "https://example.com/")!, userClicked: false, mainFrame: true)) == .cancel)
    }

    /// A page that keeps crashing shows the pane's notice instead of reloading.
    @Test func aCrashLoopShowsTheNotice() throws {
        let (view, _) = try pageView()
        defer { view.close() }
        let page = try #require(view.page)
        let stacks = { view.subviews.filter { $0 is NSStackView }.count }
        page.onCrash?(page, true)
        #expect(stacks() == 0)
        page.onCrash?(page, false)
        #expect(stacks() == 1)
    }
}
