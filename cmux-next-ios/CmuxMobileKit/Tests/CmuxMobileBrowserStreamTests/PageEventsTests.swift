import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// The page's own asks over the real stream protocol (remote-tab-protocol.md section 4):
/// new tabs (`rb.open_tab`), context menus and `<select>` (`rb.menu.*`), JavaScript
/// dialogs (`rb.dialog.*`), and Hard Reload. Each test drives a model through the
/// messages a Mac's browser host sends and reads what the phone sends back.
@MainActor @Suite struct PageEventsTests {
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    func model() async throws -> (StreamedBrowserModel, FakeStream, any BrowserStreamSink) {
        let stream = FakeStream()
        let box = SinkBox()
        let model = StreamedBrowserModel(tab: "s4", url: nil) { sink in
            box.lock.withLock { box.sinks.append(sink) }
            return stream
        }
        model.setVisible(true)
        model.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        for _ in 0..<200 where box.last == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let sink = try #require(box.last)
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        await settle()
        return (model, stream, sink)
    }

    func host(_ sink: any BrowserStreamSink, _ json: String) async {
        sink.browserMessage(Data(json.utf8))
        await settle()
    }

    func sent(_ stream: FakeStream, _ t: String) -> [[String: Any]] {
        stream.lock.withLock { stream.messages.filter { $0["t"] as? String == t } }
    }

    static let linkMenu = #"""
    {"t":"rb.menu.show","token":3,"menu":{"kind":"context","anchor":{"x":40,"y":80,"width":0,"height":0},"surface":0,
     "selected":null,"multiple":false,"right_aligned":false,"items":[
      {"id":33000,"type":"command","label":"&Back","enabled":false,"checked":false,"items":[]},
      {"id":33002,"type":"command","label":"&Reload","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":35004,"type":"command","label":"Save &As…","enabled":true,"checked":false,"items":[]},
      {"id":35011,"type":"command","label":"C&ast…","enabled":true,"checked":false,"items":[]},
      {"id":51034,"type":"command","label":"Create QR Code for this Page","enabled":true,"checked":false,"items":[]},
      {"id":35002,"type":"command","label":"View Page &Source","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":50100,"type":"command","label":"Open Link in New &Tab","enabled":true,"checked":false,"items":[]},
      {"id":50101,"type":"command","label":"Open Link in New &Window","enabled":true,"checked":false,"items":[]},
      {"id":50102,"type":"command","label":"Open Link in Inco&gnito Window","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":50103,"type":"command","label":"Save Link As…","enabled":true,"checked":false,"items":[]},
      {"id":50104,"type":"command","label":"Copy Link Address","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":50158,"type":"command","label":"Copy Link to Highlight","enabled":true,"checked":false,"items":[]},
      {"id":50191,"type":"command","label":"&Search for \u201cR&&D\u201d","enabled":true,"checked":false,"items":[]},
      {"id":35003,"type":"command","label":"&Print\u2026","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":50162,"type":"command","label":"I&nspect","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":-1,"type":"separator","label":"","enabled":true,"checked":false,"items":[]},
      {"id":50170,"type":"submenu","label":"Spelling","enabled":true,"checked":false,"items":[
        {"id":50171,"type":"check","label":"Check Spelling While &Typing","enabled":true,"checked":true,"items":[]}]},
      {"id":100,"type":"submenu","label":"Speech","enabled":true,"checked":false,"items":[
        {"id":101,"type":"command","label":"Start Speaking","enabled":true,"checked":false,"items":[]},
        {"id":102,"type":"command","label":"Stop Speaking","enabled":false,"checked":false,"items":[]}]}]}}
    """#

    // MARK: New tabs

    /// target=_blank / window.open: the phone opens the tab and tells the page which it is,
    /// as the Mac's viewer answers (`rb.open_tab.result {request, tab}`).
    @Test func aLinkThatOpensANewTabOpensOneAndAnswers() async throws {
        let (model, stream, sink) = try await model()
        var asked: [RemoteBrowserOpenTab] = []
        model.openTab = { request in
            asked.append(request)
            return "s9"
        }
        await host(sink, #"{"t":"rb.open_tab","request":7,"url":"https://example.com/next","disposition":"foreground_tab","user_gesture":true}"#)
        #expect(asked == [RemoteBrowserOpenTab(request: 7, url: "https://example.com/next", disposition: .foregroundTab, userGesture: true)])
        let answer = try #require(sent(stream, "rb.open_tab.result").first)
        #expect(answer["request"] as? Int == 7 && answer["tab"] as? String == "s9" && answer["refused"] is NSNull)
        #expect(!asked[0].opensInBackground)
    }

    /// A tab the phone could not open (or no screen to open it from) is refused, never left waiting.
    @Test func aTabThatDidNotOpenIsRefused() async throws {
        let (model, stream, sink) = try await model()
        await host(sink, #"{"t":"rb.open_tab","request":1,"url":"https://a.example/","disposition":"popup","user_gesture":true}"#)
        #expect(sent(stream, "rb.open_tab.result").first?["refused"] as? String == "refused")
        model.openTab = { _ in nil }
        await host(sink, #"{"t":"rb.open_tab","request":2,"url":"https://a.example/","disposition":"background_tab","user_gesture":true}"#)
        let answer = try #require(sent(stream, "rb.open_tab.result").last)
        #expect(answer["request"] as? Int == 2 && answer["refused"] as? String == "refused" && answer["tab"] is NSNull)
    }

    // MARK: Context menu

    /// A long press asks the page with a secondary click there, gets its menu, shows only
    /// rows that do something on the iPhone, and answers with the row picked, once.
    @Test func aLongPressShowsThePagesMenuAndAnswersOnce() async throws {
        let (model, stream, sink) = try await model()
        var got: [StreamedBrowserModel.OpenMenu?] = []
        model.requestContextMenu(x: 40, y: 80) { got.append($0) }
        let clicks = stream.lock.withLock { stream.inputs.filter { $0["e"] as? String == "pointer" && $0["button"] as? Int == 2 } }
        #expect(clicks.map { $0["kind"] as? String } == ["down", "up"])
        #expect(clicks.first?["buttons"] as? Int == 2 && clicks.first?["x"] as? Double == 40)
        await host(sink, Self.linkMenu)
        let open = try #require(got.first ?? nil)
        #expect(open.token == 3 && model.contextMenu?.token == 3)
        // Rows that act on the Mac itself (Incognito, Save, Copy, Print, Cast, QR Code, Inspect,
        // and Speech, whose ids CEF renumbers) are left out with their separators; Chromium's
        // `&` mnemonics are dropped (`&&` is `&`). Page rows stay, and so do the rows that open
        // a tab (View Page Source, Open Link in New Tab and Window, Search for): the host hands
        // their tab to the phone as `rb.open_tab` (the ids it sent on the real link, 2026-10-29).
        let rows = open.menu.phoneItems
        #expect(rows.map(\.label) == ["Back", "Reload", "", "View Page Source", "", "Open Link in New Tab",
                                      "Open Link in New Window", "", "Search for \u{201C}R&D\u{201D}", "", "Spelling"])
        #expect(rows.last?.items.map(\.label) == ["Check Spelling While Typing"])
        #expect(RemoteBrowserMenuItem.withoutMnemonic("&Search for \u{201C}R&&D\u{201D}") == "Search for \u{201C}R&D\u{201D}")
        model.choose(.command(33002), in: 3)
        // The menu closing afterwards cancels this menu only: its pick already went.
        model.choose(.cancel, in: 3)
        let results = sent(stream, "rb.menu.result")
        #expect(results.count == 1)
        #expect((results[0]["choice"] as? [String: Any])?["choice"] as? String == "command")
        #expect((results[0]["choice"] as? [String: Any])?["id"] as? Int == 33002)
        #expect(model.contextMenu == nil)
    }

    /// The menu closed with no pick: the page's menu is cancelled. A choice the menu never
    /// offered is sent as a cancel (remote-tab-protocol.md 5.2, the viewer's own check).
    @Test func aMenuClosedWithoutAPickIsCancelled() async throws {
        let (model, stream, sink) = try await model()
        model.requestContextMenu(x: 1, y: 1) { _ in }
        await host(sink, Self.linkMenu)
        model.choose(.cancel, in: 3)
        #expect((sent(stream, "rb.menu.result").last?["choice"] as? [String: Any])?["choice"] as? String == "cancel")
        model.requestContextMenu(x: 1, y: 1) { _ in }
        await host(sink, Self.linkMenu.replacingOccurrences(of: #""token":3"#, with: #""token":4"#))
        model.choose(.command(424_242), in: 4)
        let last = try #require(sent(stream, "rb.menu.result").last)
        #expect(last["token"] as? Int == 4 && (last["choice"] as? [String: Any])?["choice"] as? String == "cancel")
    }

    /// A page that handles the press itself sends no menu: the wait ends with none, and a
    /// menu that comes later (or one nobody asked for) is cancelled at once.
    @Test func noMenuInTimeSaysSoAndALateOneIsCancelled() async throws {
        let (model, stream, sink) = try await model()
        model.contextMenuTimer = { _ in }
        var got: [StreamedBrowserModel.OpenMenu?] = []
        model.requestContextMenu(x: 1, y: 1) { got.append($0) }
        await settle()
        #expect(got.count == 1 && got[0] == nil)
        await host(sink, Self.linkMenu)
        #expect(model.contextMenu == nil)
        let cancel = try #require(sent(stream, "rb.menu.result").last)
        #expect(cancel["token"] as? Int == 3 && (cancel["choice"] as? [String: Any])?["choice"] as? String == "cancel")
    }

    // MARK: Select

    static let select = #"""
    {"t":"rb.menu.show","token":5,"menu":{"kind":"select","anchor":{"x":10,"y":200,"width":180,"height":32},"surface":0,
     "selected":1,"multiple":false,"right_aligned":false,"items":[
      {"id":0,"type":"option","label":"Apple","enabled":true,"checked":false,"items":[]},
      {"id":1,"type":"option","label":"Banana","enabled":true,"checked":false,"items":[]},
      {"id":2,"type":"option","label":"Cherry","enabled":false,"checked":false,"items":[]}]}}
    """#

    @Test func selectLabelsKeepLiteralAmpersandsAndContextLabelsDropMnemonics() async throws {
        let (model, _, sink) = try await model()
        await host(sink, #"""
        {"t":"rb.menu.show","token":5,"menu":{"kind":"select","items":[
          {"id":-1,"type":"group","label":"Research & Development","items":[
            {"id":0,"type":"option","label":"R&D","items":[]},
            {"id":1,"type":"option","label":"A&&B","items":[]}]}]}}
        """#)
        let group = try #require(model.selectMenu?.menu.items.first)
        #expect(group.label == "Research & Development")
        #expect(group.items.map(\.label) == ["R&D", "A&&B"])

        model.requestContextMenu(x: 40, y: 80) { _ in }
        await host(sink, Self.linkMenu)
        let context = try #require(model.contextMenu)
        #expect(context.menu.items.first { $0.id == 50100 }?.label == "Open Link in New Tab")
        #expect(context.menu.items.first { $0.id == 50170 }?.items.first?.label == "Check Spelling While Typing")
    }

    /// `<select>`: the options show until a pick, which goes back as its index.
    @Test func aSelectShowsItsOptionsAndSendsThePick() async throws {
        let (model, stream, sink) = try await model()
        await host(sink, Self.select)
        let open = try #require(model.selectMenu)
        #expect(open.menu.items.map(\.label) == ["Apple", "Banana", "Cherry"] && open.menu.selected == 1)
        model.choose(.indices([0, 2]), in: 5)
        // Two picks in a single select are not an answer it offered.
        #expect((sent(stream, "rb.menu.result").last?["choice"] as? [String: Any])?["choice"] as? String == "cancel")
        #expect(model.selectMenu == nil)
        await host(sink, Self.select.replacingOccurrences(of: #""token":5"#, with: #""token":6"#))
        model.choose(.indices([2]), in: 6)
        let pick = try #require(sent(stream, "rb.menu.result").last?["choice"] as? [String: Any])
        #expect(pick["choice"] as? String == "indices" && pick["indices"] as? [Int] == [2])
    }

    /// The page closed its popup itself (`rb.menu.cancel`): the sheet goes, nothing is sent.
    @Test func aSelectThePageClosedGoesWithoutAnAnswer() async throws {
        let (model, stream, sink) = try await model()
        await host(sink, Self.select)
        await host(sink, #"{"t":"rb.menu.cancel","token":5}"#)
        #expect(model.selectMenu == nil)
        model.choose(.indices([1]), in: 5)
        #expect(sent(stream, "rb.menu.result").isEmpty)
    }

    // MARK: Dialogs

    /// alert, confirm and prompt as the Mac answers them: OK accepts, Cancel declines, a
    /// prompt's text goes back only when accepted.
    @Test func dialogsAnswerAsTheMacDoes() async throws {
        let (model, stream, sink) = try await model()
        await host(sink, #"{"t":"rb.dialog.show","token":1,"dialog":{"kind":"prompt","origin":"http://mac.local:8123","message":"Your name?","default_text":"Ada","is_reload":false}}"#)
        let prompt = try #require(model.dialog)
        #expect(prompt.dialog.kind == .prompt && prompt.dialog.defaultText == "Ada" && prompt.dialog.title == "http://mac.local:8123")
        #expect(prompt.dialog.hasCancel && prompt.dialog.acceptTitle == "OK")
        model.answerDialog(1, accept: true, text: "Grace")
        var answer = try #require(sent(stream, "rb.dialog.result").last)
        #expect(answer["token"] as? Int == 1 && answer["accept"] as? Bool == true && answer["text"] as? String == "Grace")
        #expect(model.dialog == nil)

        await host(sink, #"{"t":"rb.dialog.show","token":2,"dialog":{"kind":"confirm","origin":"","message":"Sure?","default_text":null,"is_reload":false}}"#)
        #expect(model.dialog?.dialog.title == "This page says")
        model.answerDialog(2, accept: false, text: "ignored")
        answer = try #require(sent(stream, "rb.dialog.result").last)
        #expect(answer["accept"] as? Bool == false && answer["text"] is NSNull)

        await host(sink, #"{"t":"rb.dialog.show","token":3,"dialog":{"kind":"beforeunload","origin":"","message":"","default_text":null,"is_reload":true}}"#)
        #expect(model.dialog?.dialog.acceptTitle == "Reload")
        await host(sink, #"{"t":"rb.dialog.show","token":4,"dialog":{"kind":"alert","origin":"","message":"Hi","default_text":null,"is_reload":false}}"#)
        // A new dialog replaces the old one; an alert has only OK.
        #expect(model.dialog?.token == 4 && model.dialog?.dialog.hasCancel == false)
    }

    /// A button belongs to the question the person saw, even if the host has
    /// cancelled it and sent another question before the alert redraws.
    @Test(arguments: [false, true])
    func aStaleDialogAnswerLeavesItsReplacementOpen(accept: Bool) async throws {
        let (model, stream, sink) = try await model()
        await host(sink, #"{"t":"rb.dialog.show","token":1,"dialog":{"kind":"confirm","origin":"","message":"First question?"}}"#)
        let shown = try #require(model.dialog)
        await host(sink, #"{"t":"rb.dialog.cancel","token":1}"#)
        await host(sink, #"{"t":"rb.dialog.show","token":2,"dialog":{"kind":"prompt","origin":"","message":"Replacement question?","default_text":"Ada"}}"#)
        let replacement = try #require(model.dialog)

        model.answerDialog(shown.token, accept: accept, text: "stale answer")
        #expect(sent(stream, "rb.dialog.result").isEmpty)
        #expect(model.dialog == replacement)

        model.answerDialog(replacement.token, accept: true, text: "Grace")
        let results = sent(stream, "rb.dialog.result")
        #expect(results.count == 1)
        let result = try #require(results.first)
        #expect(result["token"] as? Int == 2)
        #expect(result["accept"] as? Bool == true)
        #expect(result["text"] as? String == "Grace")
        #expect(model.dialog == nil)
    }

    /// The page closed its dialog itself (it navigated away): the alert goes, unanswered,
    /// and a late tap on it sends nothing. A new stream session starts with no dialog.
    @Test func aDialogThePageClosedGoesUnanswered() async throws {
        let (model, stream, sink) = try await model()
        await host(sink, #"{"t":"rb.dialog.show","token":1,"dialog":{"kind":"alert","origin":"","message":"x","default_text":null,"is_reload":false}}"#)
        await host(sink, #"{"t":"rb.dialog.cancel","token":1}"#)
        #expect(model.dialog == nil)
        model.answerDialog(1, accept: true)
        #expect(sent(stream, "rb.dialog.result").isEmpty)
        await host(sink, #"{"t":"rb.dialog.show","token":2,"dialog":{"kind":"alert","origin":"","message":"x","default_text":null,"is_reload":false}}"#)
        await host(sink, #"{"t":"welcome","caps":[]}"#)
        #expect(model.dialog == nil)
    }

    /// The page crashed or its session closed (`rb.state` crashed / closed, `rb.closed`): the
    /// open dialog, `<select>` and context menu go with it, unanswered, as the Mac's viewer
    /// closes them (cmux-remote-browser `Client::session`). A live or paused page keeps them.
    @Test(arguments: [#"{"t":"rb.state","state":"crashed"}"#, #"{"t":"rb.state","state":"closed"}"#,
                      #"{"t":"rb.closed","reason":"viewer_closed"}"#])
    func aPageThatCrashedOrClosedTakesItsDialogAndMenusWithIt(_ end: String) async throws {
        let (model, stream, sink) = try await model()
        model.requestContextMenu(x: 1, y: 1) { _ in }
        await host(sink, Self.linkMenu)
        await host(sink, Self.select.replacingOccurrences(of: #""token":5"#, with: #""token":6"#))
        await host(sink, #"{"t":"rb.dialog.show","token":1,"dialog":{"kind":"alert","origin":"","message":"x","default_text":null,"is_reload":false}}"#)
        await host(sink, #"{"t":"rb.state","state":"paused"}"#)
        #expect(model.dialog?.token == 1 && model.selectMenu?.token == 6 && model.contextMenu?.token == 3)
        await host(sink, end)
        #expect(model.dialog == nil && model.selectMenu == nil && model.contextMenu == nil)
        model.answerDialog(1, accept: true)
        model.choose(.indices([0]), in: 6)
        model.choose(.command(50100), in: 3)
        #expect(sent(stream, "rb.dialog.result").isEmpty && sent(stream, "rb.menu.result").isEmpty)
    }

    // MARK: Hard Reload

    @Test func hardReloadSkipsTheCache() async throws {
        let (model, stream, _) = try await model()
        model.hardReload()
        #expect(sent(stream, "rb.history").last?["op"] as? String == "reload_no_cache")
    }

    // MARK: Open Link in New Tab

    /// Open Link in New Tab from the page's menu: the pick goes to the page, and the tab
    /// Chromium opens for it comes back as `rb.open_tab` (the host forwards OpenURLFromTab),
    /// which opens beside the page like a target=_blank link.
    @Test func openLinkInNewTabFromThePageMenuOpensATab() async throws {
        let (model, stream, sink) = try await model()
        var asked: [RemoteBrowserOpenTab] = []
        model.openTab = { request in
            asked.append(request)
            return "s10"
        }
        model.requestContextMenu(x: 40, y: 80) { _ in }
        await host(sink, Self.linkMenu)
        let rows = try #require(model.contextMenu).menu.phoneItems
        #expect(rows.contains { $0.id == 50100 } && rows.contains { $0.id == 35002 })
        model.choose(.command(50100), in: 3)
        #expect((sent(stream, "rb.menu.result").last?["choice"] as? [String: Any])?["id"] as? Int == 50100)
        await host(sink, #"{"t":"rb.open_tab","request":1,"url":"https://example.com/linked","disposition":"background_tab","user_gesture":true}"#)
        #expect(asked.map(\.url) == ["https://example.com/linked"] && asked.first?.opensInBackground == true)
        #expect(sent(stream, "rb.open_tab.result").last?["tab"] as? String == "s10")
    }

    // MARK: Find in page

    /// Find in page: a query starts a search on the Mac (`rb.find`), its count and active
    /// match come back (`rb.find.result`), next and previous step it, and Done ends it
    /// (`rb.find.stop`). A result after Done is for no search and is ignored.
    @Test func findSearchesThePageStepsAndStops() async throws {
        let (model, stream, sink) = try await model()
        model.find("remote")
        let first = try #require(sent(stream, "rb.find").last)
        #expect(first["query"] as? String == "remote" && first["next"] as? Bool == false
            && first["forward"] as? Bool == true && first["match_case"] as? Bool == false)
        #expect(model.findResult == nil)
        await host(sink, #"{"t":"rb.find.result","matches":14,"active":1}"#)
        #expect(model.findResult == RemoteBrowserFindResult(matches: 14, active: 1))
        #expect(model.findResult?.activeIndex == 0)
        model.findNext(forward: false)
        let step = try #require(sent(stream, "rb.find").last)
        #expect(step["query"] as? String == "remote" && step["next"] as? Bool == true && step["forward"] as? Bool == false)
        await host(sink, #"{"t":"rb.find.result","matches":14,"active":14}"#)
        #expect(model.findResult?.activeIndex == 13)
        // No match: nothing is active.
        model.find("zzz")
        await host(sink, #"{"t":"rb.find.result","matches":0,"active":0}"#)
        #expect(model.findResult == RemoteBrowserFindResult(matches: 0, active: 0) && model.findResult?.activeIndex == nil)
        model.stopFind()
        #expect(sent(stream, "rb.find.stop").count == 1 && sent(stream, "rb.find.stop").last?["keep_selection"] as? Bool == true)
        #expect(model.findResult == nil && model.findQuery.isEmpty)
        await host(sink, #"{"t":"rb.find.result","matches":3,"active":1}"#)
        #expect(model.findResult == nil)
        // Nothing to step or stop once the search ended; an empty query ends a search.
        model.findNext(forward: true)
        model.stopFind()
        model.find("")
        #expect(sent(stream, "rb.find").count == 3 && sent(stream, "rb.find.stop").count == 1)
    }

    /// A new stream session has no search running: the old count goes, and the page is
    /// searched again for the query the find bar still shows. A new page drops the count too.
    @Test func aNewSessionOrPageDropsTheFindResult() async throws {
        let (model, stream, sink) = try await model()
        model.find("remote")
        await host(sink, #"{"t":"rb.find.result","matches":2,"active":1}"#)
        await host(sink, #"{"t":"welcome","caps":[]}"#)
        #expect(model.findResult == nil)
        let again = try #require(sent(stream, "rb.find").last)
        #expect(sent(stream, "rb.find").count == 2 && again["query"] as? String == "remote" && again["next"] as? Bool == false)
        await host(sink, #"{"t":"rb.find.result","matches":2,"active":1}"#)
        #expect(model.findResult?.matches == 2)
        await host(sink, #"{"t":"rb.page","url":"https://example.com/other","title":"","loading":true,"can_go_back":true,"can_go_forward":false}"#)
        #expect(model.findResult == nil)
        // Clearing the bar's results (a new query on its way) keeps the page's search.
        model.clearFindResult()
        #expect(sent(stream, "rb.find.stop").isEmpty)
    }
}
