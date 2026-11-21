@testable import CmuxNextAgentPane
import Foundation
import JavaScriptCore
import Testing

/// A New Tab context goes to its page in two parts (``AgentPaneNewTabShared`` and
/// ``AgentPaneNewTab/ownTree``), and the page's document keeps the shared part. These rows hold what the two
/// parts must give together: the whole context, also in the script that the app sends, and one shared text for
/// one value. A page that gets an own part with no shared part of its generation draws a bare screen and asks
/// again, which is a flash at the New Tab key.
@MainActor @Suite
struct NewTabContextPartsTests {
    /// A context with a value in each field, and a bar with a value in each list.
    static var full: AgentPaneNewTab {
        let icon = "data:image/png;base64,AA=="
        let tab = AgentPaneOmnibar.Tab(id: "tab", kind: .browser, title: "Tab", detail: "detail", workspace: "workspace", icon: icon)
        let action = AgentPaneOmnibar.Action(
            id: "action", title: "Action", detail: "detail", keywords: ["word"], keycaps: ["K"], symbol: "star")
        let bar = AgentPaneOmnibar(
            tabs: [tab], workspaces: [.init(id: "workspace", name: "Workspace", detail: "detail")],
            folders: ["/folder"], projects: ["/project"], actions: [action], commands: ["ls"],
            history: [.init(url: "https://example.com", title: "Example", icon: icon)],
            bookmarks: [.init(url: "https://swift.org", title: "Swift", icon: icon)],
            uses: ["workspace:workspace": 1.5], profiles: [.init(id: "profile", name: "Profile", color: "#336699")])
        let picks = AgentPaneLastPicks(
            global: .init(harness: "harness", model: "model"),
            folders: [.init(folder: "/project", harness: "harness", model: "model")])
        var page = AgentPaneNewTab(
            kind: .agent, hotkeys: [.terminal: "T", .agent: "I"], cwd: "/project", location: "https://example.com",
            omnibar: bar, projects: ["/project", "/other"], layout: .a, lastAgent: "agent", lastPicks: picks,
            home: "/home", template: "minimal")
        page.host = "Mac"
        page.warm = #"{"device":"device","sessions":[]}"#
        page.draft = "draft"
        page.app = "app"
        page.startedProject = "/project"
        page.inputToken = "input-token"
        page.focusesField = true
        page.openTabs = [tab]
        page.history = true
        page.harnessHintDismissed = true
        page.privateChatLists = true
        page.allChats = true
        page.start = AgentPaneNewTabStart(cwd: "/project", chooseFolder: true)
        return page
    }

    /// The whole context as the JSON tree of its own encoding.
    static func tree(of page: AgentPaneNewTab) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }

    /// The keys whose values differ between two trees, for a failed row's message.
    static func differences(_ one: [String: Any], _ other: [String: Any]) -> [String] {
        Set(one.keys).union(other.keys).sorted().filter { key in
            guard let left = one[key] as? NSObject, let right = other[key] as? NSObject else { return true }
            return !left.isEqual(right)
        }
    }

    /// Each field of the context is in exactly one of the two parts: the page's own tree joined with the shared
    /// text is the whole context. A field that a later change adds to the context or to the bar and that is in
    /// neither part makes this row fail: the page would get no value for it, with no error.
    @Test func theTwoPartsJoinedAreTheWholeContext() throws {
        let page = Self.full
        let whole = try Self.tree(of: page)
        let wholeBar = try #require(whole["omnibar"] as? [String: Any])
        // A field with no value has no key in the tree, so a tree with a key for each stored field has each set.
        #expect(whole.count == Mirror(reflecting: page).children.count,
                "this row's context must have a value in each field of AgentPaneNewTab (add the new field to `full`)")
        #expect(wholeBar.count == Mirror(reflecting: page.omnibar).children.count,
                "this row's bar must have a value in each list of AgentPaneOmnibar (add the new list to `full`)")
        let own = try #require(page.ownTree)
        let text = try #require(AgentPaneNewTabText().text(of: page)).text
        let shared = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let ownBar = try #require(own["omnibar"] as? [String: Any])
        let sharedBar = try #require(shared["omnibar"] as? [String: Any])
        #expect(Set(own.keys).intersection(shared.keys) == ["omnibar"], "no field of the context is in both parts")
        #expect(Set(ownBar.keys).isDisjoint(with: sharedBar.keys), "no list of the bar is in both parts")
        var joined = shared.merging(own) { _, own in own }
        let joinedBar = sharedBar.merging(ownBar) { _, own in own }
        joined["omnibar"] = joinedBar
        let lostLists = Self.differences(joinedBar, wholeBar)
        #expect(lostLists.isEmpty, "the bar's lists that the two parts do not give as the whole bar has them: \(lostLists)")
        let lost = Self.differences(joined, whole)
        #expect(lost.isEmpty, "the fields that the two parts do not give as the whole context has them: \(lost)")
    }

    /// The script that carries a context to a page (the adopt event of a page made ahead, which is the main
    /// path of a New Tab key) joins the two parts in the page's JavaScript engine. Run in an engine, the first
    /// script of a document gives the whole context from the text that it carries, and the next script, which
    /// carries the page's own part only, gives the whole context from the part that the document kept.
    @Test func theScriptsJoinGivesTheWholeContextInAJavaScriptEngine() throws {
        let engine = try #require(JSContext())
        engine.evaluateScript("var window = this")
        let model = NewTabContextTextTests.model(key: 0, text: AgentPaneNewTabText())
        let last = "\"action.\(NewTabContextTextTests.actions - 1)\""
        for key in 0..<2 {
            let context = NewTabContextTextTests.context(key: key)
            let script = try #require(model.newTabScriptValue(context))
            #expect(script.contains(last) == (key == 0), "the first script carries the shared text, the second does not")
            let result = engine.evaluateScript("JSON.stringify(" + script + ")")
            #expect(engine.exception == nil, "the script throws: \(engine.exception?.toString() ?? "")")
            let text = try #require(result?.isString == true ? result?.toString() : nil, "the script gives no object")
            var joined = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(joined.removeValue(forKey: "sharedGeneration") != nil)
            let whole = try Self.tree(of: context)
            let lost = Self.differences(joined, whole)
            #expect(lost.isEmpty, "key \(key): the fields that the join does not give as the whole context has them: \(lost)")
            #expect(joined["inputToken"] as? String == NewTabContextTextTests.token(key))
            #expect(((joined["omnibar"] as? [String: Any])?["actions"] as? [Any])?.count == NewTabContextTextTests.actions)
        }
    }

    /// A reconnect's handshake goes to a page that keeps its screen: the page reads no context from it, so
    /// the reply carries none, and the app's mark of the shared text that the document has stays. With the
    /// mark moved to a text that the page did not keep, the next script carries the own part only, and the
    /// page draws a bare screen and asks again.
    @Test func aReconnectLeavesTheMarkOfTheDocumentsSharedText() async throws {
        let model = NewTabContextTextTests.model(key: 0, text: AgentPaneNewTabText())
        let first = try #require(model.newTabScriptValue(NewTabContextTextTests.context(key: 0)))
        #expect(first.contains("\"ls\""), "the document has the first shared text")
        var changed = NewTabContextTextTests.context(key: 0)
        changed.omnibar.commands = ["ls", "swift build"]
        model.adoptNewTab(changed)
        let reply = await model.respond(to: .reconnect)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["newTab"] == nil, "the page reads no context at a reconnect")
        let next = try #require(model.newTabScriptValue(changed))
        #expect(next.contains("swift build"), "the document does not have the changed shared part: the next script carries it")
    }

    /// The warm chat list is in the shared part as the JSON text that the host made from the page's post. One
    /// list has one text, whatever the order in which the dictionaries of a post give their keys: with a text
    /// for each order, the pages of one list would have several shared parts, each with its own make and send.
    @Test func oneWarmListHasOneText() {
        let keys = ["id", "title", "cwd", "updatedAt", "harness", "model", "state", "preview"]
        func post(_ round: Int) -> [String: Any] {
            let sessions: [[String: Any]] = (0..<8).map { index in
                var session: [String: Any] = [:]
                session.reserveCapacity(round % 2 == 0 ? keys.count : 64)
                for key in round % 2 == 0 ? keys : keys.reversed() { session[key] = "\(key)-\(index)" }
                return session
            }
            var warm: [String: Any] = [:]
            warm.reserveCapacity(round % 2 == 0 ? 2 : 32)
            warm["sessions"] = sessions
            warm["device"] = "device"
            return ["method": "newTab.warm", "params": ["warm": warm]]
        }
        var texts = Set<String>()
        for round in 0..<8 {
            guard case .newTabWarm(let text) = AgentPaneRequest(body: post(round)) else {
                Issue.record("round \(round): the post is no warm list")
                continue
            }
            texts.insert(text)
        }
        #expect(texts.count == 1, "8 posts of one list gave \(texts.count) texts")
    }
}
