import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// SHORTCUT LATENCY (shared cause of Ctrl-` and Cmd-N, 2026-11-02): every tab that comes or goes
/// refreshes each open New Tab page's places (NewTabPlacesFeed) before the key's commit. The refresh
/// sent the page's whole bar (every Commands palette action, recent pages, commands, folders) to
/// change two lists: 32 of the 37 ms after Ctrl-`'s handler on cmux22 (Time Profiler, bench build),
/// most of it JSON-encoding the palette's actions. The page reads only `tabs` and `workspaces` from
/// the event (webviews newtab/adoption.ts `useNewTabPlaces`), so the refresh sends only those.
@MainActor
struct NewTabPlacesPayloadTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A New Tab page whose bar holds what a real one holds: hundreds of palette actions and recent pages.
    private static func page() -> AgentPaneNewTab {
        let actions = (0..<400).map {
            AgentPaneOmnibar.Action(id: "action.\($0)", title: "Action \($0)", detail: "Section", keywords: ["word\($0)", "other"],
                                    keycaps: ["⌘", "\($0 % 10)"])
        }
        let history = (0..<AgentPaneOmnibar.maximumEntries).map { AgentPaneOmnibar.Page(url: "https://example.com/\($0)", title: "Page \($0)") }
        return AgentPaneNewTab(kind: .agent, omnibar: AgentPaneOmnibar(
            tabs: [.init(id: "tab_old", kind: .terminal, title: "old")], folders: ["/tmp/a"], projects: ["/tmp/a"],
            actions: actions, commands: ["make"], history: history))
    }

    private static func view(_ page: AgentPaneNewTab) throws -> AgentPaneView {
        _ = NSApplication.shared
        return try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: page),
                                          source: .bundled(URL(filePath: "/dev/null"))))
    }

    /// The event's `detail` object, parsed from the script the refresh sent.
    private static func detail(_ script: String) throws -> [String: Any] {
        let prefix = "window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: "
        #expect(script.hasPrefix(prefix))
        let json = script.dropFirst(prefix.count).dropLast("}))".count)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func aPlacesRefreshSendsOnlyTheTabsAndWorkspaces() throws {
        let view = try Self.view(Self.page())
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        let tabs = [AgentPaneOmnibar.Tab(id: "tab_new", kind: .terminal, title: "new", workspace: "Work")]
        let workspaces = [AgentPaneOmnibar.Workspace(id: "ws_2", name: "Other")]
        view.refreshNewTabPlaces(tabs: tabs, workspaces: workspaces)

        #expect(scripts.count == 1)
        let detail = try Self.detail(try #require(scripts.first))
        // Only the two lists that changed: never the palette's actions, recent pages, commands or folders.
        #expect(Set(detail.keys) == ["tabs", "workspaces"])
        let sentTabs = try #require(detail["tabs"] as? [[String: Any]])
        #expect(sentTabs.map { $0["id"] as? String } == ["tab_new"])
        let sentWorkspaces = try #require(detail["workspaces"] as? [[String: Any]])
        #expect(sentWorkspaces.map { $0["name"] as? String } == ["Other"])
        // The script stays small: about the size of the two lists, not of the whole bar.
        #expect(try #require(scripts.first).utf8.count < 1_000)
    }

    @Test func thePageModelKeepsTheRestOfTheBar() throws {
        let original = Self.page()
        let view = try Self.view(original)
        view.evaluateScript = { _ in }

        let tabs = [AgentPaneOmnibar.Tab(id: "tab_new", kind: .browser, title: "new")]
        view.refreshNewTabPlaces(tabs: tabs, workspaces: [])

        let page = try #require(view.model.newTab)
        #expect(page.omnibar.tabs == tabs)
        #expect(page.omnibar.workspaces.isEmpty)
        #expect(page.omnibar.actions == original.omnibar.actions)
        #expect(page.omnibar.history == original.omnibar.history)
        #expect(page.omnibar.commands == original.omnibar.commands)
        #expect(page.omnibar.folders == original.omnibar.folders)
    }

    @Test func unchangedPlacesSendNothing() throws {
        let original = Self.page()
        let view = try Self.view(original)
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        view.refreshNewTabPlaces(tabs: original.omnibar.tabs, workspaces: original.omnibar.workspaces)

        #expect(scripts.isEmpty)
    }
}
