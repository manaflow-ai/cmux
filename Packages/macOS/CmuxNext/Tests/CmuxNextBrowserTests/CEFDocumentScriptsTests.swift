@testable import CmuxNextBrowser
import Foundation
import JavaScriptCore
import Testing

/// Browser-tab document scripts never run in a cmux page (p13-webui-068). From fork API 29 the runtime installs
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
        ]
        return groups.flatMap { group, list, scope in
            list.enumerated().map { Row(post: post, group: group, index: $0.offset, script: $0.element, expected: scope) }
        }
    }

    @Test(arguments: rows) func everyScriptHasTheGuardOfItsScope(_ row: Row) {
        #expect(row.script.scope == row.expected)
        let guarded = row.script.source.hasPrefix(CEFDocumentScripts.cmuxPageGuard)
            && row.script.source.hasSuffix(CEFDocumentScripts.cmuxPageGuardEnd)
        #expect(guarded == (row.expected == .browserTabs), "\(row.testDescription) guard: \(guarded)")
    }

    /// The table holds every script `all` installs: a new group needs its row.
    @Test(arguments: [CEFDocumentScripts.Post.binding, .pageChannel]) func theTableCoversEveryInstalledScript(_ post: CEFDocumentScripts.Post) {
        #expect(Self.rows.filter { $0.post == post }.map(\.script) == CEFDocumentScripts(post: post).all)
    }

    /// A page tab reads only the channel of the one script that runs in every document.
    @Test func onlyTheFirstPaintChannelServesCmuxPages() {
        #expect(CEFPageMessage.Channel.allCases.filter(\.servesCmuxPages) == [.firstPaint])
        let everyDocumentWorlds = Set(Self.rows.filter { $0.expected == .everyDocument }.map(\.script.world))
        #expect(everyDocumentWorlds == [CEFPageMessage.Channel.firstPaint.world])
    }

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
