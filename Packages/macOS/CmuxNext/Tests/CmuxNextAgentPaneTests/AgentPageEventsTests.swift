import CmuxNextDesign
import CmuxNextDictation
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// What the host pushes to the agent page on the shared page host (agent pane move P2): the
/// stream `cmux.agent.host.events` replaces the scripts the old host evaluated. A new subscriber
/// gets the current state first (theme, shortcuts, preview, customization), then each change.
@MainActor
@Suite struct AgentPageEventsTests {
    private func router(_ provider: AgentPageProvider) -> (PageRouter, () -> [JSONValue]) {
        let router = PageRouter(descriptor: .agent, routes: [PageRoute(prefix: "cmux.agent.", provider: provider)])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        return (router, { sent })
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func aSubscriberGetsTheCurrentStateThenEachChange() async {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [.preview(true), .shortcuts(AgentPaneShortcuts(labels: ["a": "⌘K"]))] }
        let (router, sent) = router(provider)
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(AgentPageProvider.hostEvents)])
        #expect(reply["t"]?.stringValue == "ok")
        await settle()
        provider.publish(.command("searchChats"))
        let events = sent().filter { $0["t"]?.stringValue == "ev" }
        #expect(events.map { $0["seq"]?.doubleValue } == [1, 2, 3])
        #expect(events.map { $0["data"]?["kind"]?.stringValue } == ["preview", "shortcuts", "command"])
        #expect(events[0]["data"]?["value"] == .bool(true))
        #expect(events[1]["data"]?["value"] == ["a": "⌘K"])
        #expect(events[2]["data"]?["value"] == "searchChats")
    }

    @Test func anUnsubscribedPageGetsNothingMore() async {
        let provider = AgentPageProvider { _ in nil }
        let (router, sent) = router(provider)
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(AgentPageProvider.hostEvents)])
        let sub = reply["value"]?["sub"] ?? .null
        _ = await router.handle(["t": "unsub", "sub": sub])
        provider.publish(.focusLocation)
        #expect(sent().isEmpty)
    }

    @Test func otherAgentStreamsAreUnknown() async {
        let (router, _) = router(AgentPageProvider { _ in nil })
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.agent.other"])
        #expect(reply["code"]?.stringValue == "cmux.protocol.unknown_op")
    }

    /// The theme event carries the shared web theme for the pane's surface and the pane's own values.
    @Test func theThemeEventCarriesBothThemes() throws {
        let tokens = ThemeTokens.fallback
        let event = try #require(AgentPageEvent.theme(tokens, surface: .newTabPage))
        #expect(event.kind == "theme")
        let web = try JSONValue.parse(Data(AgentPaneTheme.webTheme(tokens, surface: .newTabPage).payloadJSON.utf8))
        #expect(event.value["web"] == web)
        // The New Tab page is transparent: its pane backs it (the previous content, blurred).
        #expect(web["variables"]?["--cmux-surface-background"]?.stringValue?.hasSuffix(", 0.0)") == true)
        #expect(AgentPaneTheme.pageColor(tokens, surface: .newTabPage, backgrounds: .none).alpha == 0)
        #expect(event.value["agent"] == JSONValue(foundation: AgentPaneTheme.values(tokens, surface: .newTabPage)))
    }

    /// The style and layout go as an event; the registry does not (the view runs it as a script,
    /// AgentPaneViewPageHostTests), since the page's CSP refuses a script the page makes itself.
    @Test func customizationSendsTheStyleAndLayoutButNotTheRegistry() {
        let custom = AgentPaneCustomization(themeCSS: "a{}", registryJS: "const x = 1;", layoutJSON: #"{"b":1}"#)
        let events = AgentPageEvent.customization(custom)
        #expect(events.map(\.kind) == ["customization"])
        #expect(events[0].value == ["themeCSS": "a{}", "layout": ["b": 1]])
        // A cleared customization still clears the style a deleted theme.css left.
        let cleared = AgentPageEvent.customization(AgentPaneCustomization())
        #expect(cleared.map(\.kind) == ["customization"])
        #expect(cleared[0].value == ["themeCSS": "", "layout": .object([:])])
    }

    @Test func dictationAndRevealTurnCarryTheOldPayloads() throws {
        let update = DictationUpdate(phase: .listening, text: "hi")
        let event = try #require(AgentPageEvent.dictation(update))
        #expect(event.kind == "dictation")
        #expect(event.value == JSONValue(foundation: AgentPaneDictation.payload(update)))
        #expect(AgentPageEvent.revealTurn("t-1") == AgentPageEvent(kind: "revealTurn", value: "t-1"))
    }
}
