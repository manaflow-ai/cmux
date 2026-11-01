import AppKit
import Foundation
import CmuxNextWorkspaceNaming
import CmuxNextAgentActivity
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar

/// Agent rows prefer a readable chat title and never manufacture a raw prompt subtitle.
@MainActor @Suite(.serialized)
struct SidebarAgentRowPresentationTests {
    private static let laneSession = "0192f4c0-7e36-7a12-9d21-2c58f40a0001"
    private static let otherSession = "0192f4c0-7e36-7a12-9d21-2c58f40a0002"

    @Test func sessionNamesTravelThroughPageChangeReconnectAndPurge() throws {
        let turns = AgentTurnStateStore()
        let host = "install:sidebar-name-feed-fixture"
        turns.localHost = host
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent-sidebar-fixture", turns: turns, lanes: AgentLaneStore())
        let ref = AgentSessionRef(host: host, session: Self.laneSession, harness: "claude")
        func handle(_ object: [String: Any]) throws {
            let message = try #require(AgentTurnStateFeed.Message(line: JSONSerialization.data(withJSONObject: object)))
            feed.handle(message)
        }
        try handle(["id": 2, "result": ["sessions": [["sessionId": Self.laneSession, "name": "demo-lane", "titleSource": "named"]]]])
        #expect(turns.sessionName(for: ref) == "demo-lane")
        turns.clearLive()
        #expect(turns.sessionName(for: ref) == "demo-lane")
        try handle(["method": "_acpmux/session_changed", "params": ["sessionId": Self.laneSession,
            "session": ["sessionId": Self.laneSession, "name": "Renamed chat", "titleSource": "named"]]])
        #expect(turns.sessionName(for: ref) == "Renamed chat")
        try handle(["method": "_acpmux/session_changed", "params": ["sessionId": Self.laneSession, "kind": "purged"]])
        #expect(turns.sessionName(for: ref) == nil)
        let generatedNames: [[String: Any]] = [
            ["name": "claude-2", "harness": "claude"], ["name": "codex-fork-3", "family": "codex"],
            ["name": "optchat-sub-demo"], ["lastPrompt": "Implement the adapter"]
        ]
        for summary in generatedNames { #expect(AgentTurnStates.sessionName(summary) == nil) }
    }

    @Test func aUserPromptIsNotAConversationSubtitleButAnAgentReplyIs() throws {
        let turns = AgentTurnStateStore()
        let host = "install:sidebar-round4"
        turns.localHost = host
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent-sidebar-round4", turns: turns, lanes: AgentLaneStore())
        func handle(_ object: [String: Any]) throws {
            let message = try #require(AgentTurnStateFeed.Message(line: JSONSerialization.data(withJSONObject: object)))
            feed.handle(message)
        }
        let userSummary: [String: Any] = ["sessionId": Self.laneSession, "name": "demo-lane",
            "lastMessage": ["role": "user", "text": "Implement the adapter and report the result."]]
        try handle(["id": 2, "result": ["sessions": [userSummary]]])
        let ref = AgentSessionRef(host: host, session: Self.laneSession, harness: "claude")
        #expect(turns.lastMessage(for: ref) == nil)
        let workspace = try fixture(name: "workspace-7", nameSource: .auto, freeFormPrompt: true)
        var options = SidebarLayoutOptions()
        options.expanded = true
        for enabled in [false, true] {
            var mapped = row(workspace, machine: .local, autoNamesWorkspaces: enabled)
            mapped.lastMessage = turns.lastMessage(for: ref)
            mapped.status = "Tests running"
            #expect(options.rowContent(mapped, machine: nil).detail == "Tests running")
        }
        let agentSummary: [String: Any] = ["sessionId": Self.laneSession, "name": "demo-lane",
            "lastMessage": ["role": "agent", "text": "I finished the adapter."]]
        try handle(["id": 2, "result": ["sessions": [agentSummary]]])
        #expect(turns.lastMessage(for: ref) == "I finished the adapter.")
        var mapped = row(workspace, machine: .local, autoNamesWorkspaces: true)
        mapped.lastMessage = turns.lastMessage(for: ref)
        mapped.status = "Tests running"
        #expect(options.rowContent(mapped, machine: nil).detail == "I finished the adapter.")
        // A new user prompt must also clear a previous reply on the incremental watch path.
        try handle(["method": "_acpmux/session_changed", "params": ["sessionId": Self.laneSession, "session": userSummary]])
        #expect(turns.lastMessage(for: ref) == nil)
    }

    @Test func aPromptDerivedLaneStepUsesActivityOrPlanStep() throws {
        let prompt = String(repeating: "Implement the adapter and report the result.\n", count: 8)
        let foldedPrompt = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let summary: [String: Any] = ["sessionId": Self.laneSession, "name": "demo-lane",
            "lane": ["state": "working", "step": String(foldedPrompt.prefix(240)) + "…"],
            "turn": ["prompt": prompt, "activity": "Running tests", "planStep": "Verify output"]]
        let lane = try #require(AgentActivityLane.of(summary: summary))
        #expect(lane.turnPrompt == prompt)
        #expect(SidebarLaneStatus.step([lane]) == "Running tests")
        let planOnly = summary.merging(["turn": ["prompt": prompt, "activity": NSNull(), "planStep": "Verify output"]]) { _, new in new }
        let planLane = try #require(AgentActivityLane.of(summary: planOnly))
        #expect(SidebarLaneStatus.step([planLane]) == "Verify output")
        let folded = summary.merging(["turn": ["prompt": prompt]]) { _, new in new }
        let foldedLane = try #require(AgentActivityLane.of(summary: folded))
        #expect(SidebarLaneStatus.step([foldedLane]) == nil)
        let exact: [String: Any] = ["sessionId": Self.laneSession, "name": "demo-lane",
            "lane": ["state": "working", "step": prompt], "turn": ["prompt": prompt]]
        let exactLane = try #require(AgentActivityLane.of(summary: exact))
        #expect(SidebarLaneStatus.step([exactLane]) == nil)
        let replyOnly: [String: Any] = ["sessionId": Self.laneSession, "name": "demo-lane",
            "lane": ["state": "working", "step": "Running tests"]]
        let replyLane = try #require(AgentActivityLane.of(summary: replyOnly))
        #expect(SidebarLaneStatus.step([replyLane]) == "Running tests")
    }

    @Test func peerSessionNamesMatchFullAndShortWorkspaceNames() {
        #expect(SidebarMapping.shortSessionName("peer/demo-lane") == "demo-lane")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "demo-lane", workspaceName: "demo-lane",
            workspaceNameSource: .user, sessionName: "peer/demo-lane", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "peer/demo-lane", workspaceName: "peer/demo-lane",
            workspaceNameSource: .user, sessionName: "peer/demo-lane", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func peerNamesUseTheSameResolverAndKeepRenames() throws {
        for name in ["peer/demo-lane", "demo-lane", "workspace-7"] {
            let workspace = try fixture(name: name, nameSource: name == "workspace-7" ? .auto : .user,
                                        freeFormPrompt: true)
            let turns = turnStore(title: "peer/demo-lane", generatedTitle: nil, sessionName: "peer/demo-lane")
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "demo-lane")
            let titled = turnStore(title: "peer/demo-lane", generatedTitle: "Review the release", sessionName: "peer/demo-lane")
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: titled).title == "Review the release")
        }
        let renamed = try fixture(name: "demo-lane", nameSource: .user, nameRevision: 1)
        let turns = turnStore(title: "peer/demo-lane", generatedTitle: "Review the release", sessionName: "peer/demo-lane")
        #expect(row(renamed, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "demo-lane")
    }

    @Test func aNamedChatTitleWinsOverItsSessionName() {
        let named: [String: Any] = ["sessionId": Self.laneSession, "name": "lane-1", "title": "Review the release", "titleSource": "generated"]
        #expect(AgentTurnStates.title(named, includingPrompt: false) == "Review the release")
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: "Review the release", taskSummary: nil) == "Review the release")
    }

    @Test func aPromptWithoutAReadableTitleIsNotAStableTitle() {
        let promptOnly: [String: Any] = ["sessionId": Self.laneSession, "name": "lane-1", "lastPrompt": "Implement the adapter"]
        #expect(AgentTurnStates.title(promptOnly, includingPrompt: false) == nil)
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "lane-1", sessionName: "lane-1", chatTitle: nil, taskSummary: "Implement the adapter") == "Implement the adapter")
    }

    @Test func aLauncherNamedWorkspaceUsesItsSessionNameBeforeItsDefault() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .auto, freeFormPrompt: true)
        let turns = turnStore(title: "demo-lane", generatedTitle: nil, sessionName: "demo-lane")
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "demo-lane")
    }

    @Test func aLauncherNamedLaneUsesItsHeaderWithAUUIDSessionID() throws {
        let workspace = try fixture(name: "demo-lane", nameSource: .user, nameRevision: 0)
        let turns = turnStore(title: "demo-lane", generatedTitle: nil)
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns,
                    allowsLegacyDefaults: false).title == "Review the release")
    }

    @Test func aRenamedLauncherNameWithRevisionKeepsItsName() throws {
        let workspace = try fixture(name: "demo-lane", nameSource: .user, nameRevision: 1)
        let turns = turnStore(title: "Title: Readable task", generatedTitle: nil, sessionName: "demo-lane")
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "demo-lane")
    }

    @Test func aRestoredLegacyWorkspaceUsesItsSessionIdentity() throws {
        var restored = try JSONDecoder().decode(WorkspaceSnapshot.self,
            from: Data(#"{"id":1,"name":"demo-lane"}"#.utf8))
        #expect(restored.nameSource == .user)
        #expect(restored.nameRevision == 0)
        restored.screens = [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chatSnapshot()])])]
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [restored]))
        let workspace = try #require(store.workspaces.first)
        let turns = turnStore(title: "demo-lane", generatedTitle: "Review the release")
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "Review the release")
    }

    @Test func aRenamedAgentWorkspaceKeepsTheUserName() {
        #expect(SidebarMapping.agentRowTitle(workspaceTitle: "My review", sessionName: "lane-1",
                                             chatTitle: "Review the release", taskSummary: "Implement the adapter") == "My review")
    }

    @MainActor
    @Test func anExplicitWorkspaceTitleAlwaysWins() throws {
        let workspace = try fixture(nameSource: .auto, title: "  My review  ")
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == "  My review  ")
    }

    @MainActor
    @Test func aNamedChatTitleAlwaysWins() throws {
        let workspace = try fixture(nameSource: .auto)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        for name in ["  My chat  ", "demo-lane\ncontinued", String(repeating: "x", count: 120)] {
            tab.name = name
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == NewWorkspaceName.clean(name)!)
        }
    }

    /// #26719 (Fixes #26680): Cmd-N sends the `workspace-N` it shows, so a never-renamed
    /// `workspace-N` is no one's choice whatever source the daemon recorded, with or without
    /// the daemon's legacy-default compatibility. It takes the chat's title; a rename (below) wins.
    @MainActor
    @Test func legacyDefaultLookingUserNamesRespectDaemonCompatibility() throws {
        for legacy in [false, true] {
            let workspace = try fixture(name: "workspace-7", nameSource: .user, nameRevision: 0)
            let turns = turnStore(title: nil, generatedTitle: nil)
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns,
                        allowsLegacyDefaults: legacy).title == "Review the release")
        }
    }

    @MainActor
    @Test func aRenameToADefaultLookingNameStillWins() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .user, nameRevision: 2)
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == "workspace-7")
    }

    @MainActor
    @Test func disabledAutomaticNamingKeepsTheDefault() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .auto)
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: false).title == "workspace-7")
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == "Review the release")
    }

    @MainActor
    @Test func aFreeFormPromptDoesNotBecomeTheRowTitle() throws {
        let workspace = try fixture(nameSource: .auto, freeFormPrompt: true)
        let turns = turnStore(title: "Implement the adapter and report the result.", generatedTitle: nil)
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title == "demo-lane")
    }

    @MainActor
    @Test func aRunningTerminalFrontDoesNotUseABackgroundChatTitle() throws {
        let workspace = try fixture(nameSource: .auto, terminalFront: true)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        let terminal = try #require(tabs.first(where: { $0.agentSession == nil }))
        #expect(row(workspace, machine: .local, selectedTab: { _ in terminal.id },
                                         autoNamesWorkspaces: true).title == "npm run dev")
    }

    @MainActor
    @Test func theFrontChatUsesItsOwnTask() throws {
        let workspace = try fixture(nameSource: .auto, secondAgent: true)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        #expect(SidebarMapping.shared.agentTab(tabs)?.id == tabs[1].id)
        #expect(row(workspace, machine: .local, selectedTab: { _ in tabs[0].id },
                                         autoNamesWorkspaces: true).title == "Review the release")
        #expect(row(workspace, machine: .local, selectedTab: { _ in tabs[1].id },
                                         autoNamesWorkspaces: true).title == "Fix the other task")
    }

    @MainActor
    @Test func anUnbrandedHarnessStillGetsAReadableTaskTitle() throws {
        let workspace = try fixture()
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        #expect(tab.agentBrand == nil)
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == "Review the release")
    }

    @Test func onlyLeadingTaskHeadersCanNameTheRow() throws {
        for (prompt, expected) in [
            ("<chat>\nTitle: Context only\n</chat>\nYour task:\nGroup: Release\nTitle: Review the release", "Review the release"),
            ("<chat>\nTitle: Context only\n</chat>\nImplement the adapter", "demo-lane"),
            ("Implement the adapter\nTitle: Pasted YAML value", "demo-lane"),
            ("<chat>\nTitle: Unclosed context", "demo-lane"),
            ("Your task:\nTitle: " + String(repeating: "x", count: 120), String(repeating: "x", count: NewWorkspaceName.maxLength)),
        ] {
            let workspace = try fixture(nameSource: .auto)
            let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
            tab.agent = AgentStatus(surface: 1, state: .idle, agent: "custom-fixture-harness", lastPrompt: prompt)
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true).title == expected)
        }
    }

    @Test func aBrowserUsesItsWorkChatOnlyWhenItIsBesideIt() throws {
        for separatePane in [false, true] {
            let browser = TabSnapshot(surface: 2, kind: .browser, title: "Project docs", url: "https://example.test/docs")
            let panes = separatePane
                ? [PaneSnapshot(id: 1, focusedAt: 1, tabs: [chatSnapshot()]), PaneSnapshot(id: 2, focusedAt: 2, tabs: [browser])]
                : [PaneSnapshot(id: 1, tabs: [browser, chatSnapshot()])]
            let layout: LayoutNode = separatePane
                ? .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(1), b: .leaf(2)) : .leaf(1)
            let store = DaemonStore()
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-7", nameSource: .auto,
                screens: [ScreenSnapshot(id: 1, layout: layout, panes: panes)])]))
            let workspace = try #require(store.workspaces.first)
            let turns = turnStore(title: "demo-lane", generatedTitle: "Review the release")
            #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, turns: turns).title ==
                    (separatePane ? "Review the release" : "Project docs"))
        }
    }

    @Test func aNewTabPageDoesNotTakeTheIdleShellsName() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .auto, terminalFront: true)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        let terminal = try #require(tabs.first(where: { $0.kind == .pty }))
        terminal.applyState(nil, progress: nil)
        // An empty terminal title is idle; its cwd still supplies the name.
        terminal.title = "zsh"
        terminal.titleText = "zsh"
        let chat = try #require(tabs.first(where: { $0.agentSession != nil }))
        #expect(row(workspace, machine: .local, autoNamesWorkspaces: true, newTabPages: [chat.id]).title == "tmp")
    }

    @Test func autoNameOffPreservesTheNowLineAndIgnoresRawPromptSubtitles() throws {
        let workspace = try fixture(name: "workspace-7", nameSource: .auto, freeFormPrompt: true)
        let lane = try #require(AgentActivityLane.of(summary: ["sessionId": Self.laneSession, "name": "demo-lane",
            "lane": ["state": "working", "step": "Implement the adapter"],
            "turn": ["prompt": "Implement the adapter", "activity": "Running tests"]]))
        #expect(SidebarLaneStatus.step([lane]) == "Running tests")
        for enabled in [false, true] {
            var mapped = row(workspace, machine: .local, autoNamesWorkspaces: enabled)
            mapped.detail.task = "Implement the adapter and report the result."
            mapped.lastMessage = "Earlier reply"
            var options = SidebarLayoutOptions()
            options.expanded = true
            let beforeStep = options.rowContent(mapped, machine: nil)
            #expect(beforeStep.detail == "Earlier reply")
            #expect(beforeStep.now == nil)
            mapped.agentStep = SidebarLaneStatus.step([lane])
            let content = options.rowContent(mapped, machine: nil)
            #expect(content.now == "Running tests")
            #expect(content.detail == "Running tests")
            #expect(mapped.title == (enabled ? "demo-lane" : "workspace-7"))
        }
    }

    @Test func shownWorkspaceNameUsesTheSameSafeLabelAsTheTitlebarAndSidebar() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.machines.local.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "demo-lane", nameSource: .auto,
                screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chatSnapshot()])])])
        ]))
        let workspace = try #require(services.machines.local.store.workspaces.first)
        let chat = try #require(workspace.screens.first?.panes.first?.tabs.first)
        for (prompt, expected) in [("Implement the adapter and report the result.", "demo-lane"),
                                   ("Title: Review the release", "Review the release"),
                                   ("Implement the adapter and report the result.", "Review the release")] {
            // Once safe metadata is held, a prompt-only update must preserve that label everywhere.
            chat.agent = AgentStatus(surface: 1, state: .idle, agent: "custom-fixture-harness", lastPrompt: prompt)
            let mapped = SidebarMapping.shared.row(workspace, machine: .local, pageFace: services.sidebarPageFace)
            let names = WorkspaceAutoNameWiring(services: services).reader
            #expect(mapped.title == expected)
            #expect(names.titlebarName(workspace, selectedTab: { _ in nil }) == expected)
            #expect(services.shownWorkspaceName(workspace) == expected)
        }
    }

    private func turnStore(title: String?, generatedTitle: String?, sessionName: String? = "demo-lane") -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:sidebar-title-fixture"
        turns.apply(session: Self.laneSession, sessionName: sessionName, state: nil, lastMessage: nil, muted: false,
                    title: title, generatedTitle: generatedTitle, detail: nil)
        return turns
    }

    private func chatSnapshot() -> TabSnapshot {
        var chat = TabSnapshot(surface: 1, kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(
            host: "install:sidebar-title-fixture", session: Self.laneSession, harness: "custom-fixture-harness"))
        return chat
    }

    /// Exercise the same page-face reader as AppServices, including safe title hold and the
    /// identical face/New Tab selection used by the titlebar and palette.
    private func row(_ workspace: WorkspaceModel, machine: MachineID,
                     selectedTab: @escaping (PaneModel) -> String? = { _ in nil }, autoNamesWorkspaces: Bool,
                     turns: AgentTurnStateStore? = nil, newTabPages: Set<String> = [],
                     allowsLegacyDefaults: Bool = true) -> SidebarWorkspace {
        let names = WorkspaceAutoNameReader(enabled: { autoNamesWorkspaces }, isNewTabPage: { newTabPages.contains($0.id) },
            livePage: { _ in nil }, incognitoTitle: { _ in nil },
            terminal: { .init(kind: .terminal, userName: $0.name, title: $0.titleText, pageTitle: nil, url: nil, cwd: $0.cwd) },
            turns: turns ?? turnStore(title: "demo-lane", generatedTitle: nil), hold: WorkspaceAutoNameHold(),
            allowsLegacyDefaults: { _ in allowsLegacyDefaults })
        let mapped = SidebarMapping.shared.row(workspace, machine: machine, selectedTab: selectedTab, newTabPages: newTabPages,
            pageFace: { workspace, tab, work in .init(title: names.label(workspace, front: tab, work: work)) })
        #expect(mapped.title == names.titlebarName(workspace, selectedTab: selectedTab))
        return mapped
    }

    @MainActor
    private func fixture(name: String = "demo-lane", nameSource: WorkspaceNameSource = .user,
                         nameRevision: UInt64 = 0, title: String? = nil, secondAgent: Bool = false,
                         terminalFront: Bool = false, freeFormPrompt: Bool = false) throws -> WorkspaceModel {
        var chat = TabSnapshot(surface: 1, kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(
            host: "install:sidebar-title-fixture", session: Self.laneSession, harness: "custom-fixture-harness"))
        var chats = [chat]
        if terminalFront {
            var terminal = TabSnapshot(surface: 99, kind: .pty, cwd: "/tmp")
            terminal.title = "npm run dev"
            chats.insert(terminal, at: 0)
        }
        if secondAgent {
            var other = TabSnapshot(surface: 2, kind: .conversation, cwd: nil)
            other.conversation = ConversationTabRef(agentSession: AgentSessionRef(
                host: "install:sidebar-title-fixture", session: Self.otherSession, harness: "claude"))
            chats.append(other)
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: chats)])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: name, nameSource: nameSource, nameRevision: nameRevision,
                              screens: [screen], title: title)
        ]))
        let workspace = try #require(store.workspaces.first)
        let tabs = try #require(workspace.screens.first?.panes.first?.tabs)
        if terminalFront, let terminal = tabs.first(where: { $0.agentSession == nil }) {
            terminal.applyState(nil, progress: nil, commandSinceMs: 1)
        }
        let firstChat = try #require(tabs.first(where: { $0.agentSession != nil }))
        firstChat.agent = AgentStatus(surface: 1, state: .idle, agent: "custom-fixture-harness",
                                   lastPrompt: freeFormPrompt ? "Implement the adapter and report the result." : "Your task:\nTitle: Review the release\nCheck the build and report failures with enough detail to validate the sidebar presentation and repository facts.")
        if secondAgent {
            let secondChat = try #require(tabs.last(where: { $0.agentSession != nil }))
            secondChat.agent = AgentStatus(surface: 2, state: .working, agent: "claude",
                                       lastPrompt: "Your task:\nTitle: Fix the other task\nCheck a separate project.")
        }
        return workspace
    }

}
