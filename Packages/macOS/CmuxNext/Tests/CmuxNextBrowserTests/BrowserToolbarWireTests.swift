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

    /// The status names its tab slot and the text that tab would leave unsent (`OmnibarDraft`).
    @Test func theStatusCarriesItsTabAndDraft() {
        let status = OmnibarStatus(wire: ["phase": "editing", "editing": true, "text": "weather",
                                          "tab": "slot-a", "draft": ["text": "weather", "selection": [3, 2]]])
        #expect(status.tab == "slot-a")
        #expect(status.draft == OmnibarDraft(text: "weather", selection: NSRange(location: 3, length: 2)))
        #expect(OmnibarStatus(wire: ["draft": NSNull()]).draft == nil)
        #expect(OmnibarStatus(wire: ["draft": ["text": "", "selection": [0, 0]]]).draft == nil, "an empty draft is none")
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
        _ = try JSONSerialization.data(withJSONObject: BrowserToolbarHostEvent.rowClick(0, shown: nil, meta: true, shift: false, alt: false))
        // A click names the row the card drew there, so rows replaced in the same push never take it.
        let drawn = BrowserSuggestion(kind: .history, title: "First", detail: "", url: URL(string: "https://first.example/")!, score: 1)
        let click = BrowserToolbarHostEvent.rowClick(0, shown: drawn, meta: false, shift: false, alt: false)
        _ = try JSONSerialization.data(withJSONObject: click)
        let shown = try #require(click["shown"] as? [String: Any])
        #expect(shown["kind"] as? String == "history" && shown["url"] as? String == "https://first.example/")
    }

    @Test func tabBringsTheKeysToTheRowAndAClickDoesNot() throws {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)
        }
        #expect(BrowserToolbarWebView.isKeyboardNavigation(key(48)))
        #expect(BrowserToolbarWebView.isKeyboardNavigation(key(48, .shift)))
        #expect(!BrowserToolbarWebView.isKeyboardNavigation(key(48, .control)))
        #expect(!BrowserToolbarWebView.isKeyboardNavigation(key(0)))
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(!BrowserToolbarWebView.isKeyboardNavigation(click))
        #expect(!BrowserToolbarWebView.isKeyboardNavigation(nil))
    }

    @Test func aClickInTheCardsShadowMarginGoesToTheWindowBelow() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [], backing: .buffered, defer: true)
        let card = OmniboxPopupWindow()
        card.setFrame(NSRect(x: 300, y: 300, width: 224, height: 200), display: false)
        card.placeCard(margin: (top: 0, right: 12, bottom: 12, left: 12), upward: false, cornerRadius: 8)
        func click(at point: NSPoint, _ type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: card.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // On a row: the card's.
        #expect(OmniboxPopupWindow.forwarded(click(at: NSPoint(x: 100, y: 100)), outside: card.cardRect, from: card, to: parent) == nil)
        // In the side margin, over Reload: the window below's, at the same spot on screen.
        let moved = try #require(OmniboxPopupWindow.forwarded(click(at: NSPoint(x: 4, y: 150)), outside: card.cardRect, from: card, to: parent))
        #expect(moved.type == .leftMouseDown)
        #expect(parent.convertPoint(toScreen: moved.locationInWindow) == NSPoint(x: 304, y: 450))
        // A move is never handed on.
        #expect(OmniboxPopupWindow.forwarded(click(at: NSPoint(x: 4, y: 150), .mouseMoved), outside: card.cardRect, from: card, to: parent) == nil)
    }

    @Test func aSearchEngineChangeReachesAMountedRow() throws {
        let engine = OmniboxSuggestionEngine()
        let bar = BrowserToolbarWebView(suggestionEngine: engine)
        let before = engine.display.configurationRevision
        let google = try #require(bar.wireState()["omnibar"] as? [String: Any])["searchEngine"] as? NSObject
        engine.apply(OmniboxConfiguration(searchEngine: .duckDuckGo))
        // The row's display loop reads the revision, so it pushes the new resolver settings.
        #expect(engine.display.configurationRevision == before + 1)
        let duck = try #require(bar.wireState()["omnibar"] as? [String: Any])["searchEngine"] as? NSObject
        #expect(google != duck)
    }

    @Test func aTitleChangePushesOnlyWhenTheTitleChanged() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.pageTitleChanged("One")
        #expect(bar.pushScheduled)
        bar.pushNow()
        bar.pageTitleChanged("One")
        #expect(!bar.pushScheduled)
        bar.pageTitleChanged("Two")
        #expect(bar.pushScheduled)
    }

    @Test func anOmnibarRowWithNoNavigationYetDrawsReloadOff() throws {
        let row = OmnibarToolbarView(suggestionEngine: OmniboxSuggestionEngine(), navigation: true)
        let navigation = try #require(row.addressBar.wireState()["navigation"] as? [String: Bool])
        #expect(navigation["canReload"] == false)
        row.setNavigation(canGoBack: false, canGoForward: false, canReload: true)
        #expect((row.addressBar.wireState()["navigation"] as? [String: Bool])?["canReload"] == true)
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
        #expect(navigation == ["canGoBack": true, "canGoForward": false, "loading": true, "canReload": true])
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
        #expect(state["draft"] is NSNull, "a tab with no draft sends none")
    }

    /// A tab that comes from another pane names its draft with its slot (`ToolbarHostState.draft`).
    @Test func aMovedTabsSlotComesWithItsDraft() throws {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.showTab("slot-c", shownURL: URL(string: "https://c.example/"),
                    draft: OmnibarDraft(text: "weather", selection: NSRange(location: 3, length: 2)))
        let data = try JSONSerialization.data(withJSONObject: bar.wireState())
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let draft = try #require(state["draft"] as? [String: Any])
        #expect(draft["text"] as? String == "weather")
        #expect(draft["selection"] as? [Int] == [3, 2])
    }

    /// A command the page made for the tab that left (an older binding) never runs on the tab that
    /// came: A's Enter arriving after the chrome bound B navigates nothing. The ack and the layout
    /// are the row's, and run from any binding.
    @Test func aCommandOfAnOlderBindingIsDropped() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        var commands: [BrowserToolbarPageCommand] = []
        var ended: [OmnibarEvent] = []
        bar.onCommand = { commands.append($0) }
        bar.onEvent = { ended.append($0) }
        bar.showTab("slot-a", shownURL: URL(string: "https://a.example/"))
        let a = bar.binding
        #expect(bar.wireState()["binding"] as? Int == a)
        bar.showTab("slot-b", shownURL: URL(string: "https://b.example/"))
        #expect(bar.binding > a, "every tab shown moves the binding")
        let commit: [String: Any] = ["type": "effect", "effect": ["type": "ended", "reason": ["kind": "commit", "url": "https://a.example/typed"]]]
        bar.received("command", commit.merging(["binding": a]) { $1 })
        bar.received("command", ["type": "goBack", "binding": a])
        bar.received("command", ["type": "reload"])
        #expect(ended.isEmpty && commands.isEmpty, "A's commit and buttons never act on B")
        bar.send(BrowserToolbarHostEvent.blur)
        bar.received("command", ["type": "ack", "seq": 1, "binding": a])
        #expect((bar.wireState()["events"] as? [Any])?.isEmpty == true, "an ack runs from any binding")
        bar.received("command", ["type": "goBack", "binding": bar.binding])
        bar.received("command", commit.merging(["binding": bar.binding]) { $1 })
        #expect(commands == [.goBack])
        #expect(ended.count == 1, "B's own commit runs")
    }

    /// A host event carries the binding it was queued under; the tab let go moves the binding too.
    @Test func hostEventsCarryTheirBinding() throws {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.showTab("slot-a", shownURL: nil)
        bar.send(BrowserToolbarHostEvent.enter(.currentTab))
        let queued = bar.binding
        bar.beginBinding()
        bar.send(BrowserToolbarHostEvent.forgetTab("slot-a"))
        let entries = try #require(bar.wireState()["events"] as? [[String: Any]])
        #expect(entries.map { $0["binding"] as? Int } == [queued, queued + 1])
        #expect(OmniboxPopupCommand.revision(["type": "pick", "index": 0, "revision": 4]) == 4)
    }

    /// The card stays in its pane (AddressBarView clipped it to `cardPane`): in a short split it
    /// is cut to the room under the bar (above it, upward), and the page scrolls the rows within.
    @Test func theSuggestionCardStaysInItsPane() {
        let pane = NSRect(x: 100, y: 300, width: 600, height: 200)
        let bar = NSRect(x: 110, y: 440, width: 580, height: 28)
        #expect(OmniboxCardPlacement.maxCardHeight(bar: bar, upward: false, clip: pane) == 140)
        #expect(OmniboxCardPlacement.cardHeight(400, limit: 140) == 140)
        #expect(OmniboxCardPlacement.cardHeight(90, limit: 140) == 90, "a short card keeps its height")
        #expect(OmniboxCardPlacement.cardHeight(400, limit: nil) == 400)
        // A bottom row opens upward: the room above the bar.
        let bottomBar = NSRect(x: 110, y: 304, width: 580, height: 28)
        #expect(OmniboxCardPlacement.maxCardHeight(bar: bottomBar, upward: true, clip: pane) == 168)
        // No room at all still shows a row.
        #expect(OmniboxCardPlacement.maxCardHeight(bar: NSRect(x: 0, y: 300, width: 10, height: 28), upward: false, clip: pane)
            == OmniboxCardPlacement.minimumHeight)
        #expect(OmniboxCardPlacement.maxCardHeight(bar: bar, upward: false, clip: nil) == nil)
        // The screen's visible frame cuts a pane that reaches past it.
        let screen = NSRect(x: 0, y: 350, width: 1440, height: 900)
        #expect(OmniboxCardPlacement.clip(pane: pane, screen: screen) == NSRect(x: 100, y: 350, width: 600, height: 150))
        #expect(OmniboxCardPlacement.clip(pane: pane, screen: nil) == pane)
    }

    /// A Finder file dropped on the row (WebKit hides its path from the page): the field takes the
    /// keys and the file's URL, as AddressBarView's drop did; a read-only row takes nothing.
    @Test func aFinderFileDropReachesTheField() throws {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.acceptFileDrop(URL(fileURLWithPath: "/Users/me/My Notes.html"))
        let events = try #require(bar.wireState()["events"] as? [[String: Any]]).compactMap { $0["event"] as? [String: Any] }
        #expect(events.map { $0["kind"] as? String } == ["focus", "dropped"])
        #expect(events.last?["text"] as? String == "file:///Users/me/My%20Notes.html")
        let readOnly = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        readOnly.isReadOnly = true
        readOnly.acceptFileDrop(URL(fileURLWithPath: "/tmp/a.txt"))
        #expect((readOnly.wireState()["events"] as? [Any])?.isEmpty == true)
    }

    /// VoiceOver hears the row the highlight moves to (the field, another web view, cannot point
    /// at the card's row), never the same row again.
    @Test func theHighlightedRowIsAnnounced() {
        let rows = [
            BrowserSuggestion(kind: .search, title: "weather", detail: "", url: URL(string: "https://s.example/?q=weather")!, score: 1),
            BrowserSuggestion(kind: .history, title: "Docs", detail: "docs.example.com", url: URL(string: "https://docs.example.com/")!, score: 1),
        ]
        #expect(OmniboxPopupPanel.announcement(rows: rows, highlighted: 0, previous: nil) == "weather")
        #expect(OmniboxPopupPanel.announcement(rows: rows, highlighted: 1, previous: 0) == "Docs, docs.example.com")
        #expect(OmniboxPopupPanel.announcement(rows: rows, highlighted: 1, previous: 1) == nil)
        #expect(OmniboxPopupPanel.announcement(rows: rows, highlighted: nil, previous: 1) == nil)
        #expect(OmniboxPopupPanel.announcement(rows: rows, highlighted: 5, previous: 1) == nil)
    }

    /// A glass look (`regular`, `clear`) tells the page the host draws glass under its bar, so it
    /// draws no flat fill; the flat looks do not.
    @Test func theStateSaysWhetherTheBarIsGlass() {
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        let look = bar.wireState()["look"] as? [String: Any]
        #expect(look?["glass"] as? Bool == bar.drawsBarGlass)
        #expect(look?["material"] as? String == OmnibarGlassLook.current.material.rawValue)
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

/// A toolbar page that crashes and reloads starts from the field's latest unsent text.
@MainActor
struct BrowserToolbarReloadDraftTests {
    final class RecordingContent: BrowserChromeWebContent {
        let view = NSView()
        var pushed: [[String: Any]] = []
        var kept: [String: Any]?
        var onMessage: ((String, [String: Any]) -> Void)?
        var focusView: NSView { view }
        var acceptsKeyFocus: (() -> Bool)?
        var onResignedKeys: (() -> Void)?
        var contextMenuEditor: (@MainActor (NSMenu) -> Void)?
        func push(_ state: [String: Any]) { pushed.append(state) }
        func keepForReload(_ state: [String: Any]) { kept = state }
        func focus() {}
        func close() {}
    }

    @Test func theReloadStateCarriesTheTextTypedSinceTheLastPush() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.pushNow()
        #expect(content.pushed.count == 1)
        content.onMessage?("command", ["type": "status", "editing": true, "text": "hello", "tab": bar.tabSlot, "binding": bar.binding,
                                       "draft": ["text": "hello", "selection": [5, 0]]])
        // Typing pushes nothing to the running page.
        #expect(content.pushed.count == 1)
        let draft = try #require(content.kept?["draft"] as? [String: Any])
        #expect(draft["text"] as? String == "hello")
        // Another tab's late status leaves the reload state alone.
        content.kept = nil
        content.onMessage?("command", ["type": "status", "text": "x", "tab": "other", "binding": bar.binding, "draft": ["text": "x", "selection": [1, 0]]])
        #expect(content.kept == nil)
    }

    @Test func aLaterPushStillCarriesTheTextTypedSince() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.pushNow()
        content.onMessage?("command", ["type": "status", "editing": true, "text": "hello", "tab": bar.tabSlot, "binding": bar.binding,
                                       "draft": ["text": "hello", "selection": [5, 0]]])
        // Any later push (here the page's URL) is what a reload starts from: it keeps the typed text.
        bar.reportedURL = URL(string: "https://example.com/")
        bar.pushNow()
        let pushed = try #require(content.pushed.last?["draft"] as? [String: Any])
        #expect(pushed["text"] as? String == "hello")
        content.onMessage?("command", ["type": "status", "editing": true, "text": "hello!", "tab": bar.tabSlot, "binding": bar.binding,
                                       "draft": ["text": "hello!", "selection": [6, 0]]])
        let kept = try #require(content.kept?["draft"] as? [String: Any])
        #expect(kept["text"] as? String == "hello!")
    }

    @Test func aTabShownAgainRestsOnTheDraftItBringsNotAStaleReport() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.showTab("tab-a", shownURL: nil)
        bar.pushNow()
        content.onMessage?("command", ["type": "status", "editing": true, "text": "old", "tab": "tab-a", "binding": bar.binding,
                                       "draft": ["text": "old", "selection": [3, 0]]])
        // The tab moves to another pane, gets newer text there, and comes back with it.
        bar.showTab("tab-b", shownURL: nil)
        bar.showTab("tab-a", shownURL: nil, draft: OmnibarDraft(text: "newer", selection: NSRange(location: 5, length: 0)))
        bar.pushNow()
        let draft = try #require(content.pushed.last?["draft"] as? [String: Any])
        #expect(draft["text"] as? String == "newer")
    }

    @Test func aReloadedPageNeverRunsAnAckedRequestAgain() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.pushNow()
        bar.send(BrowserToolbarHostEvent.focus("keyboard"))
        bar.pushNow()
        let queued = try #require(content.pushed.last?["events"] as? [[String: Any]])
        let last = try #require(queued.last?["seq"] as? Int)
        content.onMessage?("command", ["type": "ack", "seq": last, "binding": bar.binding])
        let kept = try #require(content.kept?["events"] as? [[String: Any]])
        #expect(kept.isEmpty)
    }

    @Test func theFirstRightClickOnARestingFieldOffersPasteAndGo() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.pasteAndGo.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/", forType: .string)
        bar.pasteboard = pasteboard
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.pushNow()
        // At rest the field offers nothing to paste into.
        #expect(!bar.isEditing)
        #expect(bar.pasteAndGoTitle(editing: bar.isEditing) == nil)
        // The right-click focuses it; the page has not reported editing yet, and the menu offers it.
        bar.giveKeys(source: "mouse")
        #expect(bar.isEditing)
        #expect(bar.pasteAndGoTitle(editing: bar.isEditing) == Strings.pasteAndGo)
        pasteboard.clearContents()
        pasteboard.setString("cmux omnibar", forType: .string)
        #expect(bar.pasteAndGoTitle(editing: true) == Strings.pasteAndSearch)
    }

    @Test func restoringFocusGivesTheKeysBackWhileTheStatusStillSaysEditing() throws {
        let content = RecordingContent()
        let bar = BrowserToolbarWebView(suggestionEngine: OmniboxSuggestionEngine())
        bar.makeWebContent = { content }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(bar)
        bar.pushNow()
        // The page's status lags the blur the host sent when another tab's field took the keys.
        content.onMessage?("command", ["type": "status", "editing": true, "text": "a", "tab": bar.tabSlot, "binding": bar.binding])
        #expect(bar.isEditing)
        #expect(window.firstResponder !== content.focusView)
        bar.restoreFocus()
        bar.pushNow()
        let events = try #require(content.pushed.last?["events"] as? [[String: Any]])
        #expect(events.contains { ($0["event"] as? [String: Any])?["kind"] as? String == "focus" })
    }
}
