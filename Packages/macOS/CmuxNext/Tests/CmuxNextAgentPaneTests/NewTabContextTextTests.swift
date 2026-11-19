import AppKit
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A New Tab page's context has two parts. The larger part is the same for each page of a window: the bar's
/// workspaces, folders, actions, commands and recent pages. The smaller part is the page's own: the token of
/// the keys typed before its field is ready, its folder, and the bar's open tabs, which a held New Tab key
/// changes at each key. The host makes the JSON of the larger part one time for the pages that share it, and
/// a page gets it one time. Each make and each send of it is main thread time in the frames of a New Tab key.
@MainActor @Suite
struct NewTabContextTextTests {
    struct Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    }

    static let actions = 50

    /// The context of the page that the key number `key` of a hold opens: its own token, one more open tab
    /// than the page before it, and the same bar otherwise.
    static func context(key: Int) -> AgentPaneNewTab {
        let tabs = (0...key).map { AgentPaneOmnibar.Tab(id: "tab-\($0)", kind: .agent, title: "Tab \($0)") }
        let listed = (0..<actions).map { AgentPaneOmnibar.Action(id: "action.\($0)", title: "Action \($0)") }
        let bar = AgentPaneOmnibar(
            tabs: tabs, workspaces: [.init(id: "workspace", name: "Workspace")], folders: ["/project"],
            actions: listed, commands: ["ls"], history: [.init(url: "https://example.com", title: "Example")])
        var page = AgentPaneNewTab(kind: .agent, cwd: "/project", omnibar: bar)
        page.inputToken = token(key)
        return page
    }

    static func token(_ key: Int) -> String { "input-token-\(key)" }

    static func model(key: Int, text: AgentPaneNewTabText) -> AgentPaneModel {
        let model = AgentPaneModel(host: Host(), newTab: context(key: key))
        model.startFolders.resolve = { _ in nil }
        model.newTabText = text
        return model
    }

    /// The `newTab` object of a reply's value.
    static func newTab(of reply: [String: Any]) throws -> [String: Any] {
        let value = try #require(reply["value"] as? [String: Any])
        return try #require(value["newTab"] as? [String: Any])
    }

    /// The pages of a hold share the bar's larger part: its JSON is made one time for all of them, at the
    /// page's early ask for its context and at its handshake.
    @Test func thePagesOfAHoldCostOneEncodeOfTheSharedPart() async throws {
        let text = AgentPaneNewTabText()
        for key in 0..<4 {
            let model = Self.model(key: key, text: text)
            _ = await model.respond(to: .newTabContext)
            _ = await model.respond(to: .ready)
        }
        #expect(text.encodes == 1, "4 pages, each asks for its context and shakes hands: one make of the shared part")
    }

    /// The shared part goes as one text that the page parses, so the reply's tree has one node for it. The
    /// page's own part stays in the tree: each page gets its own token and its own open tabs, and the shared
    /// text holds neither.
    @Test func eachPageGetsItsOwnTokenBesideTheSharedText() async throws {
        let text = AgentPaneNewTabText()
        var shared: [String] = []
        for key in 0..<2 {
            let model = Self.model(key: key, text: text)
            let newTab = try await Self.newTab(of: model.respond(to: .newTabContext))
            #expect(newTab["inputToken"] as? String == Self.token(key))
            let bar = try #require(newTab["omnibar"] as? [String: Any])
            #expect((bar["tabs"] as? [Any])?.count == key + 1, "the page's own open tabs")
            // How large each part is in this scene (a bar of 50 actions, no icons): what the tree carries for each
            // page, and what goes as the one text.
            let own = try JSONSerialization.data(withJSONObject: newTab.filter { $0.key != "shared" }).count
            let sizes = "the page's own part \(own) bytes, the shared text \((newTab["shared"] as? String)?.utf8.count ?? 0) bytes"
            print("NewTabContextTextTests: key \(key): \(sizes)")
            #expect(bar["actions"] == nil, "the shared lists are not in the tree (\(sizes))")
            let part = try #require(newTab["shared"] as? String, "the shared part is one text")
            #expect(!part.contains("input-token-"), "no page's token is in the text that the pages share")
            let parsed = try #require(try JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any])
            let parsedBar = try #require(parsed["omnibar"] as? [String: Any])
            #expect((parsedBar["actions"] as? [Any])?.count == Self.actions, "the page joins the bar from the text")
            #expect(parsedBar["tabs"] == nil)
            shared.append(part)
        }
        #expect(shared.count == 2 && shared[0] == shared[1], "the 2 pages get the same text")
    }

    /// A page that got the shared text at its early ask has it: its handshake sends the page's own part only.
    @Test func theHandshakeAfterTheEarlyAskSendsNoSharedPartAgain() async throws {
        let model = Self.model(key: 0, text: AgentPaneNewTabText())
        let early = try await Self.newTab(of: model.respond(to: .newTabContext))
        #expect(early["shared"] is String)
        let handshake = try await Self.newTab(of: model.respond(to: .ready))
        #expect(handshake["inputToken"] as? String == Self.token(0))
        #expect(handshake["shared"] == nil, "the page has the shared text of its early ask")
        #expect((handshake["omnibar"] as? [String: Any])?["actions"] == nil, "and no list of it comes in the tree")
    }

    /// The shared part changed after the page's early ask: the page's document has the older text, so its
    /// handshake carries the new one.
    @Test func aChangeOfTheSharedPartBetweenTheTwoSendsReachesThePage() async throws {
        let model = Self.model(key: 0, text: AgentPaneNewTabText())
        let early = try await Self.newTab(of: model.respond(to: .newTabContext))
        let first = try #require(early["shared"] as? String)
        var changed = Self.context(key: 0)
        changed.omnibar.commands = ["ls", "swift build"]
        model.adoptNewTab(changed)
        let handshake = try await Self.newTab(of: model.respond(to: .ready))
        let second = try #require(handshake["shared"] as? String, "the page's document has the older text")
        #expect(second != first)
        #expect(second.contains("swift build"))
    }

    /// A page that has no shared part (its state is lost) asks for its context again: an ask always gets the
    /// shared text, also when the host sent the same text to that page before.
    @Test func anAskForTheContextAlwaysGetsTheSharedText() async throws {
        let text = AgentPaneNewTabText()
        let model = Self.model(key: 0, text: text)
        _ = await model.respond(to: .newTabContext)
        _ = await model.respond(to: .ready)
        let again = try await Self.newTab(of: model.respond(to: .newTabContext))
        #expect(again["shared"] is String)
        #expect(text.encodes == 1, "the same text: no second make")
    }

    /// A page that did not ask early gets the shared text with its handshake.
    @Test func aHandshakeWithNoEarlyAskCarriesTheSharedText() async throws {
        let model = Self.model(key: 0, text: AgentPaneNewTabText())
        let handshake = try await Self.newTab(of: model.respond(to: .ready))
        #expect(handshake["inputToken"] as? String == Self.token(0))
        #expect(handshake["shared"] is String)
    }

    /// A script that carries the context (the adopt event, the context of a document's commit) has the shared
    /// text as it is, one time for a document: the next script has the page's own part only, which the page
    /// joins with the part that its document keeps. A new document gets the text again, with no second make.
    @Test func aScriptCarriesTheSharedTextOneTimeForADocument() throws {
        let text = AgentPaneNewTabText()
        let model = Self.model(key: 0, text: text)
        let last = "\"action.\(Self.actions - 1)\""
        let first = try #require(model.newTabScriptValue(Self.context(key: 0)))
        #expect(first.contains(last), "a document with no shared text gets it")
        let second = try #require(model.newTabScriptValue(Self.context(key: 1)))
        #expect(!second.contains(last), "the same shared part: the page's own part only")
        #expect(second.contains(Self.token(1)))
        print("NewTabContextTextTests: a script with the shared text \(first.utf8.count) bytes, with the own part only \(second.utf8.count) bytes")
        let commit = try #require(model.newTabScriptValue(Self.context(key: 1), always: true))
        #expect(commit.contains(last), "a new document gets the shared text")
        #expect(text.encodes == 1, "one make of the shared part for the 3 scripts")
    }

    /// The pages that the app makes have one keeper of the shared text (``AgentPaneShared/newTabText``): each
    /// page's view gives it to its model. With a keeper for each page, each page of a hold costs a make.
    @Test func thePagesOverTheAppsSharedObjectsHaveOneKeeperOfTheText() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html></html>".utf8).write(to: file)
        let shared = AgentPaneShared()
        let pages = try (0..<2).map { key in
            try #require(AgentPaneView(model: AgentPaneModel(host: Host(), newTab: Self.context(key: key)), source: .bundled(file), shared: shared), "fixture: no page")
        }
        defer {
            pages.forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        for page in pages {
            #expect(page.model.newTabText === shared.newTabText)
            _ = page.model.newTabReply(Self.context(key: 0), always: true)
        }
        #expect(shared.newTabText.encodes == 1, "2 pages over one shared value: one make")
    }
}
