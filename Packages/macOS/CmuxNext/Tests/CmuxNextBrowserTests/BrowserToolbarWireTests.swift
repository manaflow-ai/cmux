import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The toolbar row's wire to its React pages (webviews/src/pages/browser-toolbar and
/// omnibox-popup; the TypeScript side is browser-chrome/toolbar/wire.ts).
@MainActor
struct BrowserToolbarWireTests {
    // MARK: Commands the toolbar page sends

    @Test func everyPressThePageSendsParses() {
        #expect(BrowserToolbarPageCommand(wire: ["type": "goBack"]) == .goBack)
        #expect(BrowserToolbarPageCommand(wire: ["type": "goForward"]) == .goForward)
        #expect(BrowserToolbarPageCommand(wire: ["type": "reload"]) == .reload)
        #expect(BrowserToolbarPageCommand(wire: ["type": "stop"]) == .stop)
        #expect(BrowserToolbarPageCommand(wire: ["type": "navigationMenu", "direction": "back"]) == .navigationMenu(.back))
        #expect(BrowserToolbarPageCommand(wire: ["type": "navigationMenu", "direction": "forward"]) == .navigationMenu(.forward))
        #expect(BrowserToolbarPageCommand(wire: ["type": "navigationMenu", "direction": "reload"]) == .navigationMenu(.reload))
        #expect(BrowserToolbarPageCommand(wire: ["type": "pageInfo"]) == .pageInfo)
        #expect(BrowserToolbarPageCommand(wire: ["type": "bookmark"]) == .bookmark)
        #expect(BrowserToolbarPageCommand(wire: ["type": "toolbarButton", "button": "overflow"]) == .toolbarButton(.overflow))
        #expect(BrowserToolbarPageCommand(wire: ["type": "extensionAction", "id": "abc"]) == .extensionAction("abc"))
        #expect(BrowserToolbarPageCommand(wire: ["type": "extensionContextMenu", "id": "abc"]) == .extensionContextMenu("abc"))
        #expect(BrowserToolbarPageCommand(wire: ["type": "extensionsMenu"]) == .extensionsMenu)
        #expect(BrowserToolbarPageCommand(wire: ["type": "reloadCrashedExtensions"]) == .reloadCrashedExtensions)
        #expect(BrowserToolbarPageCommand(wire: ["type": "moveExtension", "id": "abc", "index": 2]) == .moveExtension("abc", index: 2))
        #expect(BrowserToolbarPageCommand(wire: ["type": "focusModeBadge"]) == .focusModeBadge)
        #expect(BrowserToolbarPageCommand(wire: ["type": "profileBadge"]) == .profileBadge)
        #expect(BrowserToolbarPageCommand(wire: ["type": "machineBadge"]) == .machineBadge)
        #expect(BrowserToolbarPageCommand(wire: ["type": "requestFocus"]) == .requestFocus)
        #expect(BrowserToolbarPageCommand(wire: ["type": "ack", "seq": 7]) == .ack(7))
    }

    @Test func aCommandOutsideTheRowsChoicesIsRefused() {
        #expect(BrowserToolbarPageCommand(wire: ["type": "runScript"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: [:]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "navigationMenu", "direction": "up"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "toolbarButton", "button": "nonsense"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "extensionAction"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "moveExtension", "id": "abc"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "ack"]) == nil)
        #expect(BrowserToolbarPageCommand(wire: ["type": "effect", "effect": ["type": "nonsense"]]) == nil)
    }

    // MARK: The omnibar reducer's effects and ends

    @Test func everyEffectParses() {
        func effect(_ wire: [String: Any]) -> OmnibarPageEffect? {
            guard case .effect(let effect)? = BrowserToolbarPageCommand(wire: ["type": "effect", "effect": wire]) else { return nil }
            return effect
        }
        let url = URL(string: "https://example.com/a")!
        #expect(effect(["type": "query", "generation": 3, "text": "exa"]) == .query(generation: 3, text: "exa"))
        #expect(effect(["type": "cancelQuery"]) == .cancelQuery)
        #expect(effect(["type": "beep"]) == .beep)
        #expect(effect(["type": "began"]) == .began)
        #expect(effect(["type": "deleteSuggestion", "url": url.absoluteString]) == .deleteSuggestion(url))
        #expect(effect(["type": "typedNavigation", "url": url.absoluteString]) == .typedNavigation(url))
        #expect(effect(["type": "typedHTTPSUpgrade", "url": url.absoluteString]) == .typedHTTPSUpgrade(url))
        #expect(effect(["type": "hostTypoFixed", "typedHost": "exmaple.com"]) == .hostTypoFixed("exmaple.com"))
        #expect(effect(["type": "copyAnswer", "text": "42"]) == .copyAnswer("42"))
        #expect(effect(["type": "keywordStarted", "extensionID": "ext"]) == .keywordStarted("ext"))
        #expect(effect(["type": "keywordInput", "extensionID": "ext", "text": "milk", "generation": 4])
            == .keywordInput(extensionID: "ext", text: "milk", generation: 4))
        #expect(effect(["type": "keywordEnded", "extensionID": "ext"]) == .keywordEnded("ext"))
        // A query without its generation could answer a later one: refused.
        #expect(effect(["type": "query", "text": "exa"]) == nil)
        #expect(effect(["type": "deleteSuggestion"]) == nil)
    }

    @Test func everyEndReasonParses() {
        let url = "https://example.com/"
        #expect(OmnibarEndReason(wire: ["kind": "commit", "url": url]) == .commit(URL(string: url)!))
        #expect(OmnibarEndReason(wire: ["kind": "open", "url": url, "disposition": "newBackgroundTab"]) == .open(URL(string: url)!, .newBackgroundTab))
        #expect(OmnibarEndReason(wire: ["kind": "open", "url": url]) == .open(URL(string: url)!, .currentTab))
        #expect(OmnibarEndReason(wire: ["kind": "cancel"]) == .cancel)
        #expect(OmnibarEndReason(wire: ["kind": "blur"]) == .blur)
        #expect(OmnibarEndReason(wire: ["kind": "keyword", "extensionID": "ext", "text": "milk", "disposition": "newWindow"])
            == .keyword(extensionID: "ext", text: "milk", disposition: .newWindow))
        #expect(OmnibarEndReason(wire: ["kind": "switchToTab", "key": "tab_1"]) == .switchToTab(key: "tab_1"))
        #expect(OmnibarEndReason(wire: ["kind": "commit"]) == nil)
        #expect(OmnibarEndReason(wire: ["kind": "keyword", "extensionID": "ext"]) == nil)
    }

    /// A read-only row (a sign-in window) turns any navigating end into a cancel.
    @Test func aReadOnlyRowNeverNavigates() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.isReadOnly = true
        var ends: [OmnibarEndReason] = []
        bar.onEvent = { if case .didEndEditing(let reason) = $0 { ends.append(reason) } }
        bar.handle(.effect(.ended(.commit(URL(string: "https://evil.example.net/")!))))
        bar.handle(.effect(.ended(.blur)))
        #expect(ends == [.cancel, .blur])
    }

    // MARK: Status, layout, popup

    @Test func theStatusParses() {
        let status = OmnibarStatus(wire: ["phase": "editing", "editing": true, "popupOpen": true, "text": "exa",
                                          "selection": [3, 0], "elided": false, "rows": ["Example", "Example 2"], "highlighted": 1])
        #expect(status.isEditing && status.isPopupOpen)
        #expect(status.text == "exa")
        #expect(status.selection == NSRange(location: 3, length: 0))
        #expect(status.rows == ["Example", "Example 2"])
        #expect(status.highlighted == 1)
        #expect(OmnibarStatus(wire: [:]) == OmnibarStatus())
    }

    @Test func theStatusDrivesEditing() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        #expect(!bar.isEditing)
        bar.handle(.status(OmnibarStatus(wire: ["editing": true, "text": "abc"])))
        #expect(bar.isEditing && bar.displayedText == "abc")
        bar.handle(.effect(.ended(.cancel)))
        #expect(!bar.isEditing)
    }

    @Test func theLayoutReportParsesAndPlacesAnchors() throws {
        let report = BrowserToolbarLayoutReport(wire: ["rects": ["omnibar": [80, 4, 400, 28], "back": [8, 4, 28, 28], "bad": [1, 2]],
                                                       "showsForward": false, "visiblePinned": 2, "collapse": 1])
        #expect(report.rects["omnibar"] == CGRect(x: 80, y: 4, width: 400, height: 28))
        #expect(report.rects["bad"] == nil)
        #expect(!report.showsForward && report.visiblePinned == 2 && report.collapse == 1)

        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        var reported: BrowserToolbarLayoutReport?
        bar.onLayout = { reported = $0 }
        bar.handle(.layout(report))
        #expect(reported == report)
        let back = try #require(bar.anchor("back"))
        #expect(back.frame == CGRect(x: 8, y: 4, width: 28, height: 28))
        #expect(back.hitTest(NSPoint(x: 10, y: 10)) == nil, "an anchor never takes a click from the page")
        // A control the page no longer draws loses its anchor.
        bar.handle(.layout(BrowserToolbarLayoutReport(wire: ["rects": ["omnibar": [80, 4, 400, 28]]])))
        #expect(bar.anchor("back") == nil)
    }

    @Test func thePopupCommandCarriesItsRows() {
        let row: [String: Any] = ["kind": "history", "title": "Example", "detail": "example.com", "url": "https://example.com/", "score": 1]
        let command = BrowserToolbarPageCommand(wire: ["type": "popup", "rows": [row, ["kind": "nonsense"]], "highlighted": 0, "upward": true])
        guard case .popup(let rows, let highlighted, let upward)? = command else {
            Issue.record("not a popup command: \(String(describing: command))")
            return
        }
        #expect(rows.map(\.title) == ["Example"], "a row the host cannot read is dropped")
        #expect(highlighted == 0 && upward)
    }

    @Test func thePopupPagesCommandsParse() {
        #expect(OmniboxPopupCommand(wire: ["type": "hover", "index": 2, "pointer": ["x": 10, "y": 20]]) == .hover(2, pointer: CGPoint(x: 10, y: 20)))
        #expect(OmniboxPopupCommand(wire: ["type": "hover", "pointer": ["x": 1, "y": 2]]) == .hover(nil, pointer: CGPoint(x: 1, y: 2)))
        #expect(OmniboxPopupCommand(wire: ["type": "pick", "index": 1, "modifiers": ["meta": true, "shift": false, "alt": true]])
            == .pick(1, meta: true, shift: false, alt: true))
        #expect(OmniboxPopupCommand(wire: ["type": "pick"]) == nil)
        #expect(OmniboxPopupCommand(wire: ["type": "runScript"]) == nil)
    }

    // MARK: Suggestions round trip

    @Test func aSuggestionSurvivesTheRoundTrip() throws {
        var row = BrowserSuggestion(kind: .switchToTab, title: "Docs", detail: "docs.example.com", url: URL(string: "https://docs.example.com/")!, score: 0.5)
        row.content = "docs"
        row.inlineCompletable = false
        row.tabKey = "tab_7"
        let data = try JSONSerialization.data(withJSONObject: row.wire)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let back = try #require(BrowserSuggestion(wire: decoded))
        #expect(back.kind == .switchToTab && back.title == "Docs" && back.detail == "docs.example.com")
        #expect(back.url == row.url && back.score == 0.5)
        #expect(back.content == "docs" && !back.inlineCompletable && back.tabKey == "tab_7")
        for kind in [BrowserSuggestion.Kind.navigate, .search, .history, .bookmark, .keyword, .switchToTab, .answer] {
            #expect(BrowserSuggestion.Kind(wire: kind.wire) == kind)
        }
    }

    // MARK: Host to page

    @Test func hostEventsQueueInOrderUntilThePageAcks() throws {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.send(BrowserToolbarHostEvent.focus("keyboard"))
        bar.send(BrowserToolbarHostEvent.blur)
        bar.send(BrowserToolbarHostEvent.enter(.newBackgroundTab))
        func events() -> [(seq: Int, event: [String: Any])] {
            (bar.wireState()["events"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let seq = entry["seq"] as? Int, let event = entry["event"] as? [String: Any] else { return nil }
                return (seq, event)
            }
        }
        let queued = events()
        #expect(queued.map(\.seq) == [1, 2, 3])
        #expect(queued.map { $0.event["kind"] as? String } == ["focus", "blur", "key"])
        #expect(queued[0].event["source"] as? String == "keyboard")
        let key = try #require(queued[2].event["key"] as? [String: Any])
        #expect(key["kind"] as? String == "enter" && key["disposition"] as? String == "newBackgroundTab")
        bar.handle(.ack(2))
        #expect(events().map(\.seq) == [3], "an acked event is not sent again")
        bar.handle(.ack(3))
        #expect(events().isEmpty)
        // Every event serializes as JSON.
        _ = try JSONSerialization.data(withJSONObject: BrowserToolbarHostEvent.suggestions(1, []))
        _ = try JSONSerialization.data(withJSONObject: BrowserToolbarHostEvent.rowHover(nil, pointer: .zero))
        _ = try JSONSerialization.data(withJSONObject: BrowserToolbarHostEvent.rowClick(0, meta: true, shift: false, alt: false))
    }

    @Test func theStateSerializesAndCarriesTheRow() throws {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.update(url: URL(string: "https://example.com/a"), security: .secure)
        bar.navigation = ToolbarNavigation(canGoBack: true, canGoForward: false, loading: true)
        bar.setFocusModeBadge(armed: false)
        let data = try JSONSerialization.data(withJSONObject: bar.wireState())
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(state["url"] as? String == "https://example.com/a")
        #expect(state["tab"] as? String == "default")
        let navigation = try #require(state["navigation"] as? [String: Bool])
        #expect(navigation == ["canGoBack": true, "canGoForward": false, "loading": true])
        #expect(state["showsButtons"] as? Bool == true)
        let site = try #require(state["site"] as? [String: Any])
        #expect(site["displayName"] as? String == "example.com")
        let metrics = try #require(state["metrics"] as? [String: Any])
        for key in ["bar", "button", "fontSize", "barTop", "spacing", "margin", "cornerRadius", "maxPinned"] {
            #expect(metrics[key] != nil, "metrics.\(key) is missing")
        }
        let omnibar = try #require(state["omnibar"] as? [String: Any])
        #expect(omnibar["readOnly"] as? Bool == false)
        #expect(omnibar["searchEngine"] is [String: Any])
        #expect((state["badges"] as? [String: Any])?["focusMode"] is [String: Any])
    }

    /// A tab switch names the shown slot; nothing else of the other tabs is sent (the page keeps
    /// each tab's resting omnibar itself).
    @Test func aTabSwitchSendsOnlyTheSlotAndItsAddress() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.showTab("slot-b", shownURL: URL(string: "https://b.example/"))
        let state = bar.wireState()
        #expect(state["tab"] as? String == "slot-b")
        #expect(state["url"] as? String == "https://b.example/")
        #expect((state["events"] as? [Any])?.isEmpty == true, "a switch queues no event")
    }

    @Test func aButtonsStateHasThePagesShape() throws {
        let state = BrowserToolbarPolicy.state(.overflow, BrowserToolbarFacts(engine: .cef, hostsDevTools: true))
        let wire = state.wire(.overflow, pressed: true)
        #expect(wire["id"] as? String == "overflow")
        #expect(wire["pressed"] as? Bool == true)
        for key in ["icon", "label", "enabled", "active", "tooltip", "opensMenu", "collapseLevel"] {
            #expect(wire[key] != nil, "\(key) is missing")
        }
        _ = try JSONSerialization.data(withJSONObject: wire)
    }
}
