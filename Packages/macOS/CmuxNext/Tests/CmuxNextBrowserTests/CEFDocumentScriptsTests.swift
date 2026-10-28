@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// Browser-tab document scripts never run in a cmux page. From fork API 29 the runtime installs
/// them in every renderer, page renderers included (`CEFDocumentScripts.installInRenderer`), so each one starts with
/// the cmux-page guard; only the first paint, which page tabs read too, runs in every document.
@Suite struct CEFDocumentScriptsTests {
    /// One document script of one install path, with the documents it must be for.
    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let post: CEFDocumentScripts.Post
        let group: String
        let index: Int
        let script: CEFDocumentScripts.Script
        let expected: CEFDocumentScripts.Scope
        var testDescription: String { "\(post) \(group)[\(index)]" }
    }

    /// Every script of both install paths (DevTools bindings before fork API 29, page channels from it).
    nonisolated static let rows: [Row] = [CEFDocumentScripts.Post.binding, .pageChannel].flatMap { post -> [Row] in
        let scripts = CEFDocumentScripts(post: post)
        let groups: [(String, [CEFDocumentScripts.Script], CEFDocumentScripts.Scope)] = [
            ("media", scripts.media, .browserTabs),
            ("verification", scripts.verification, .browserTabs),
            ("firstPaint", scripts.firstPaint, .everyDocument),
            ("pageHost", scripts.pageHost, .cmuxPages),
        ]
        return groups.flatMap { group, list, scope in
            list.enumerated().map { Row(post: post, group: group, index: $0.offset, script: $0.element, expected: scope) }
        }
    }

    @Test(arguments: rows) func everyScriptHasTheGuardOfItsScope(_ row: Row) {
        #expect(row.script.scope == row.expected)
        let ends = row.script.source.hasSuffix(CEFDocumentScripts.cmuxPageGuardEnd)
        let guarded = row.script.source.hasPrefix(CEFDocumentScripts.cmuxPageGuard) && ends
        let pageOnly = row.script.source.hasPrefix(CEFDocumentScripts.cmuxPageOnlyGuard) && ends
        #expect(guarded == (row.expected == .browserTabs), "\(row.testDescription) guard: \(guarded)")
        #expect(pageOnly == (row.expected == .cmuxPages), "\(row.testDescription) page-only guard: \(pageOnly)")
    }

    /// The table holds every script `all` installs: a new group needs its row.
    @Test(arguments: [CEFDocumentScripts.Post.binding, .pageChannel]) func theTableCoversEveryInstalledScript(_ post: CEFDocumentScripts.Post) {
        #expect(Self.rows.filter { $0.post == post }.map(\.script) == CEFDocumentScripts(post: post).all)
    }

    /// A page tab reads only the channels of the scripts that run in cmux pages: the first paint (every document)
    /// and the page host relay (cmux pages only), which a browser tab never reads.
    @Test func onlyTheFirstPaintAndPageHostChannelsServeCmuxPages() {
        #expect(CEFPageMessage.Channel.allCases.filter(\.servesCmuxPages) == [.firstPaint, .pageHost])
        #expect(CEFPageMessage.Channel.allCases.filter { !$0.servesBrowserTabs } == [.pageHost])
        let everyDocumentWorlds = Set(Self.rows.filter { $0.expected == .everyDocument }.map(\.script.world))
        #expect(everyDocumentWorlds == [CEFPageMessage.Channel.firstPaint.world])
        let pageWorlds = Set(Self.rows.filter { $0.expected == .cmuxPages }.map(\.script.world))
        #expect(pageWorlds == [CEFPageMessage.Channel.pageHost.world])
        #expect(Self.rows.filter { $0.expected == .cmuxPages }.allSatisfy { !$0.script.allFrames }, "the relay is the main frame's")
    }

    /// The page host relay posts the page's event text on its channel, stamped with the URL of the
    /// document it runs in, and cancels the event, so the page sends no binding call; it runs only in a cmux page.
    @Test(arguments: documents) func thePageHostRelayPostsOnlyInACmuxPage(_ document: Document) throws {
        let context = try Self.context(document)
        context.evaluateScript(Self.domStub + "location.href = 'cmux-page://agent/index.html#/chat';")
        let relay = try #require(CEFDocumentScripts(post: .pageChannel).pageHost.first)
        context.evaluateScript(relay.source)
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        let taken = context.evaluateScript("fire('[1,2]')").toBool()
        #expect(taken == (document.scheme == "cmux-page:"), "the relay took the post: \(taken)")
        let posted = context.evaluateScript("posts.join('|')").toString()
        #expect(posted == (document.scheme == "cmux-page:" ? "cmuxPageHost cmux-page://agent/index.html#/chat\n[1,2]" : ""))
    }

    /// The host reads the relay's stamp back: the sender's URL and the page's text, newlines in the text kept; a
    /// post with no stamp is not the relay's.
    @Test func aPageHostPostSplitsIntoItsSenderAndText() throws {
        let post = try #require(CEFDocumentScripts.pageHostPost("cmux-page://agent/index.html\n{\"a\":\"x\\ny\"}\nz"))
        #expect(post.sender.absoluteString == "cmux-page://agent/index.html")
        #expect(post.text == "{\"a\":\"x\\ny\"}\nz")
        #expect(CEFDocumentScripts.pageHostPost(#"{"name":"cmuxPage"}"#) == nil)
    }

    /// A relay whose channel is missing (a refused channel) leaves the event uncancelled: the page falls back.
    @Test func thePageHostRelayLeavesAPostWithNoChannel() throws {
        let context = try Self.context(Document(scheme: "cmux-page:", origin: "cmux-page://agent", runs: false))
        context.evaluateScript(Self.domStub + "cmuxPost = undefined;")
        let relay = try #require(CEFDocumentScripts(post: .pageChannel).pageHost.first)
        context.evaluateScript(relay.source)
        #expect(context.evaluateScript("fire('x')").toBool() == false)
        #expect(CEFDocumentScripts(post: .binding).pageHost.isEmpty, "the DevTools path has no relay")
    }

    /// `document.addEventListener` / `dispatchEvent` for one cancelable event, a `cmuxPost` that records its posts,
    /// and `fire(text)`, which answers whether a listener cancelled the event.
    static let domStub = """
    var posts = [];
    var listeners = [];
    var cmuxPost = function (channel, text) { posts.push(channel + ' ' + text); };
    var document = {
      addEventListener: function (type, listener) { listeners.push({ type: type, listener: listener }); },
      dispatchEvent: function (event) {
        for (var i = 0; i < listeners.length; i++) if (listeners[i].type === event.type) listeners[i].listener(event);
        return !event.defaultPrevented;
      },
    };
    function fire(text) {
      var event = { type: '\(CEFDocumentScripts.pageHostEvent)', detail: text, defaultPrevented: false,
                    preventDefault: function () { this.defaultPrevented = true; }, stopImmediatePropagation: function () {} };
      return !document.dispatchEvent(event);
    }
    """

    /// A document as the guard sees it.
    nonisolated struct Document: Sendable, CustomTestStringConvertible {
        let scheme: String
        let origin: String
        let runs: Bool
        var testDescription: String { "\(scheme) in \(origin)" }
    }

    /// A cmux page, a frame that inherits its origin, and a cmux page of a non-standard scheme (opaque origin) skip
    /// the body; a web page and its `about:blank` frame run it.
    nonisolated static let documents = [
        Document(scheme: "https:", origin: "https://example.com", runs: true),
        Document(scheme: "about:", origin: "https://example.com", runs: true),
        Document(scheme: "cmux-page:", origin: "cmux-page://settings", runs: false),
        Document(scheme: "cmux-page:", origin: "null", runs: false),
        Document(scheme: "about:", origin: "cmux-page://settings", runs: false),
    ]

    @Test(arguments: documents) func theGuardRunsTheBodyOnlyOutsideACmuxPage(_ document: Document) throws {
        let context = try Self.context(document)
        let script = CEFDocumentScripts.Script(world: "", body: "ran = true;", allFrames: true, scope: .browserTabs)
        context.evaluateScript(script.source)
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        #expect(context.evaluateScript("ran").toBool() == document.runs)
    }

    /// Each real browser-tab script still parses inside the guard, and runs nothing in a cmux page.
    @Test(arguments: rows.filter { $0.expected == .browserTabs }) func aGuardedScriptParsesAndDoesNothingInACmuxPage(_ row: Row) throws {
        let context = try Self.context(Document(scheme: "cmux-page:", origin: "cmux-page://settings", runs: false))
        context.evaluateScript(row.script.source)
        #expect(context.exception == nil, "\(row.testDescription): \(String(describing: context.exception))")
        #expect(context.evaluateScript("ran").toBool() == false)
    }

    /// A JavaScriptCore global standing in for `document`'s window: its `location.protocol` and `origin`.
    static func context(_ document: Document) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("var ran = false; var location = { protocol: '\(document.scheme)' }; var origin = '\(document.origin)';")
        return context
    }
}
