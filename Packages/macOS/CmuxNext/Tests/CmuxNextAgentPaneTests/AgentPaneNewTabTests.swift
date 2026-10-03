import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The new tab page's host side (#16620): the handshake carries the page,
/// and a terminal or browser pick reaches the App.
@MainActor
@Suite struct AgentPaneNewTabTests {
    private let page = AgentPaneNewTab(kind: .browser, hotkeys: [.terminal: "⌃⇧⌘T", .agent: "⇧⌘I"], cwd: "~/code/cmux")

    @Test func aNewTabPageHandshakeCarriesKindHotkeysAndFolder() async throws {
        let model = AgentPaneModel(
            host: MockAgentPaneHost(),
            newTab: AgentPaneNewTab(
                kind: page.kind, hotkeys: [.terminal: "⌃⇧⌘T", .agent: "⇧⌘I"], cwd: page.cwd,
                projects: ["/src/app", "/src/web"]
            )
        )
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        let newTab = try #require(value["newTab"] as? [String: Any])
        #expect(newTab["kind"] as? String == "browser")
        #expect(newTab["hotkeys"] as? [String: String] == ["terminal": "⌃⇧⌘T", "agent": "⇧⌘I"])
        #expect(newTab["cwd"] as? String == "~/code/cmux")
        #expect(newTab["projects"] as? [String] == ["/src/app", "/src/web"])
        // The mock host sets no newSession of its own; the page still opens empty.
        #expect(value["newSession"] as? Bool == true)
    }

    /// An agent chat started from the page runs in the page's folder, like a
    /// terminal picked there, on the first handshake and after a reconnect.
    @Test func aChatFromTheNewTabPageStartsInItsFolder() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: page)
        for request in [AgentPaneRequest.ready, .reconnect] {
            let value = try #require(await model.respond(to: request)["value"] as? [String: Any])
            #expect(value["cwd"] as? String == "~/code/cmux")
        }
    }

    /// A seed's folder (the tab it was opened from) still wins over the page's.
    @Test func aSeedsFolderWinsOverThePages() async throws {
        let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: "/tmp/worktree"))
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: seed, newTab: page)
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect(value["cwd"] as? String == "/tmp/worktree")
    }

    @Test func aPlainChatHasNoNewTabPage() async throws {
        let reply = await AgentPaneModel(host: MockAgentPaneHost()).respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["newTab"] == nil)
    }

    /// Once the page became a chat, a reload shows the chat, not the page.
    @Test func theChatsFirstSessionRetiresThePage() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: page)
        _ = await model.respond(to: .persistSession("s-1"))
        #expect(model.newTab == nil)
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["newTab"] == nil)
        var opened = 0
        model.onOpenTab = { _, _, _ in opened += 1 }
        #expect(await model.respond(to: .openTab(.terminal, text: "ls"))["ok"] as? Bool == false)
        #expect(opened == 0)
    }

    @Test func pickingTerminalOrBrowserReachesTheApp() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: page)
        var opened: [String] = []
        var edited: [AgentPaneTabKind] = []
        var jumped: [String] = []
        model.onOpenTab = { opened.append("\($0.rawValue):\($1)\($2.map { "@" + $0 } ?? "")") }
        model.onJump = { jumped.append("\($0.rawValue):\($1)") }
        model.onEditShortcut = { edited.append($0) }
        #expect(await model.respond(to: .openTab(.terminal, text: "bun dev"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .openTab(.browser, text: "localhost:5173"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .openTab(.terminal, text: "", cwd: "/src/api"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .jump(.tab, id: "tab-7"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .editShortcut(.agent))["ok"] as? Bool == true)
        #expect(opened == ["terminal:bun dev", "browser:localhost:5173", "terminal:@/src/api"])
        #expect(jumped == ["tab:tab-7"])
        #expect(edited == [.agent])
    }

    @Test func requestsParseOnlyKnownKinds() {
        func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
            AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
        }
        #expect(request("tab.open", ["kind": "terminal", "text": "ls"]) == .openTab(.terminal, text: "ls"))
        #expect(request("tab.open", ["kind": "browser"]) == .openTab(.browser, text: ""))
        // The page starts an agent chat itself; only other kinds reach Swift.
        #expect(request("tab.open", ["kind": "agent", "text": "hi"]) == .unsupported("tab.open"))
        #expect(request("tab.open", ["kind": "spreadsheet"]) == .unsupported("tab.open"))
        let long = String(repeating: "a", count: AgentPaneRequest.maximumOpenTabText + 10)
        #expect(request("tab.open", ["kind": "terminal", "text": long]) == .openTab(.terminal, text: String(long.prefix(AgentPaneRequest.maximumOpenTabText))))
        // A folder row opens a terminal there; a browser has no folder.
        #expect(request("tab.open", ["kind": "terminal", "text": "", "cwd": "/src/api"]) == .openTab(.terminal, text: "", cwd: "/src/api"))
        #expect(request("tab.open", ["kind": "browser", "text": "x", "cwd": "/src/api"]) == .openTab(.browser, text: "x"))
        #expect(request("tab.jump", ["target": "workspace", "id": "ws-1"]) == .jump(.workspace, id: "ws-1"))
        #expect(request("tab.jump", ["target": "window", "id": "w"]) == .unsupported("tab.jump"))
        #expect(request("tab.jump", ["target": "tab", "id": ""]) == .unsupported("tab.jump"))
        #expect(request("shortcut.edit", ["kind": "agent"]) == .editShortcut(.agent))
        #expect(request("shortcut.edit", [:]) == .unsupported("shortcut.edit"))
        #expect(request("action.run", ["id": "palette.welcomeChecklist"]) == .runAction("palette.welcomeChecklist"))
        #expect(request("action.run", ["id": "closeWindow"]) == .runAction("closeWindow"))
        #expect(request("tab.setDefaultKind", ["kind": "auto"]) == .setDefaultKind("auto"))
        #expect(request("tab.setDefaultKind", ["kind": ""]) == .unsupported("tab.setDefaultKind"))
        #expect(request("tab.setDefaultKind", ["kind": String(repeating: "a", count: 40)]) == .unsupported("tab.setDefaultKind"))
    }

    @Test func newTabRunsOnlyTheImportAndSyncAction() async {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: page)
        var actions: [String] = []
        model.onRunAction = { actions.append($0) }
        #expect(await model.respond(to: .runAction("palette.welcomeChecklist"))["ok"] as? Bool == true)
        #expect(await model.respond(to: .runAction("closeWindow"))["ok"] as? Bool == false)
        #expect(actions == ["palette.welcomeChecklist"])
    }

    /// The "default: X" toggle: the handshake says what Cmd-T opens, and a
    /// pick reaches the App only while the tab is still the page.
    @Test func theDefaultToggleReachesTheAppWhileThePageIsShown() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .terminal, defaultKind: "same-kind"))
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        #expect((value["newTab"] as? [String: Any])?["defaultKind"] as? String == "same-kind")
        var picked: [String] = []
        model.onSetDefaultKind = { picked.append($0) }
        #expect(await model.respond(to: .setDefaultKind("agent"))["ok"] as? Bool == true)
        _ = await model.respond(to: .persistSession("s-1"))
        #expect(await model.respond(to: .setDefaultKind("page"))["ok"] as? Bool == false)
        #expect(picked == ["agent"])
    }

    @Test func theHandshakeCarriesTheLocationAndLosslessSuggestions() async throws {
        let tabs = (0..<50).map { AgentPaneOmnibar.Tab(id: "t\($0)", kind: .terminal, title: "t\($0)") }
        let page = AgentPaneNewTab(kind: .browser, location: "https://vite.dev/guide/", omnibar: AgentPaneOmnibar(
            tabs: tabs, workspaces: [AgentPaneOmnibar.Workspace(id: "w1", name: "docs-site")], folders: ["/src/app"],
            history: [AgentPaneOmnibar.Page(url: "https://vite.dev/config/", title: "Configuring Vite")]
        ))
        let model = AgentPaneModel(host: MockAgentPaneHost(), newTab: page)
        let value = try #require(await model.respond(to: .ready)["value"] as? [String: Any])
        let newTab = try #require(value["newTab"] as? [String: Any])
        #expect(newTab["location"] as? String == "https://vite.dev/guide/")
        let omnibar = try #require(newTab["omnibar"] as? [String: Any])
        #expect((omnibar["tabs"] as? [[String: Any]])?.count == 50)
        #expect((omnibar["workspaces"] as? [[String: Any]])?.first?["name"] as? String == "docs-site")
        #expect((omnibar["workspaces"] as? [[String: Any]])?.first?["detail"] == nil)
        #expect(omnibar["folders"] as? [String] == ["/src/app"])
        #expect((omnibar["history"] as? [[String: Any]])?.first?["title"] as? String == "Configuring Vite")
    }
}
