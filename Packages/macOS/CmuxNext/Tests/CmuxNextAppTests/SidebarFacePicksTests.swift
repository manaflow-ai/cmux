@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// `SidebarMapping.faceTabs` names one workspace for the titlebar, the auto namer and Copy Agent Identifier. It gives
/// the face rules the title, folder, running command and title activity of the front tab only, so a caller in an
/// observation is not woken by another tab's (a terminal retitles on every command; the titlebar's name read all 84
/// tabs of a 14-pane workspace, `NewTabWakesDoNotGrowWithSessionTests`). The rules must then pick the same tabs as
/// from every tab's facts, which is what the sidebar rows give them.
@MainActor @Suite struct SidebarFacePicksTests {
    /// The writes one tracking heard; read on the main actor after the write, which runs `onChange` in place.
    private nonisolated final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// The picked tabs' ids, in the order front, label, face, work, chat.
    private static func ids(_ tabs: [TabModel?]) -> [String] { tabs.map { $0?.id ?? "none" } }

    /// The mixed workspaces of `SidebarFaceCostTests` (idle shells beside chats, running commands, agents, pages,
    /// New Tab pages, two panes with different focus times).
    @Test func thePicksFromTheFrontTabsFactsAreThePicksFromEveryTabsFacts() throws {
        let selectedTab = SidebarFaceCostTests.selectedTab
        for index in 0 ..< 96 {
            let request = SidebarFaceCostTests.request(index)
            let full = SidebarFaceBatch(home: SidebarFaceCostTests.home)
            full.reset(showsUnread: false, newTabTitled: false)
            full.append(request.workspace, local: true, status: nil, selectedTab: selectedTab, newTabPages: request.newTabPages,
                        listTitle: \.displayTitle, branded: { _ in false })
            let all = try #require(full.run(), "the face rules read workspace \(index)").picks(0)
            let tabs = full.tabs
            let expected = Self.ids([all.front, all.label, all.face, all.work, all.chat].map { $0.map { tabs[$0] } })
            let picks = SidebarMapping.shared.faceTabs(request.workspace, selectedTab: selectedTab, newTabPages: request.newTabPages)
            #expect(Self.ids([picks.front, picks.label, picks.face, picks.work, picks.chat]) == expected, "workspace \(index)")
            #expect(SidebarMapping.shared.frontTab(request.workspace, selectedTab: selectedTab)?.id == expected[0], "workspace \(index)")
        }
    }

    /// An idle shell in front, and beside it a pane of a second shell and an agent chat: the picks follow the front
    /// tab's title (an idle shell yields the name to the chat, a shell at work keeps it) and no other tab's.
    @Test func thePicksReadTheTitleOfTheFrontTabOnly() throws {
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 3), kind: .conversation, title: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:picks", session: "s1", harness: "claude"))
        let panes = [
            PaneSnapshot(id: .init(rawValue: 1), focusedAt: 2, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .pty, title: "zsh")]),
            PaneSnapshot(id: .init(rawValue: 2), focusedAt: 1, tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .pty, title: "zsh"), chat]),
        ]
        let screens = panes.map { ScreenSnapshot(id: .init(rawValue: $0.id.rawValue), layout: .leaf($0.id), panes: [$0]) }
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: .init(rawValue: 1), key: WorkspaceKey(rawValue: "picks"),
                                                         name: "workspace-1", screens: screens))
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        try #require(tabs.count == 3, "fixture: \(tabs.count) tabs, not 3")
        let front = tabs[0], other = tabs[1]
        func picks() -> SidebarMapping.FaceTabs { SidebarMapping.shared.faceTabs(workspace, selectedTab: { _ in nil }) }
        func wakes(_ write: () -> Void) -> Int {
            let counter = Counter()
            withObservationTracking { _ = picks() } onChange: { counter.value += 1 }
            write()
            return counter.value
        }
        #expect(picks().front === front)
        #expect(picks().label === tabs[2], "the idle shell in front leaves the name to the chat")
        let forAnother = wakes { other.titleText = "npm run dev" }
        #expect(forAnother == 0, "another tab's title woke the reader of the picks")
        #expect(picks().label === tabs[2])
        let forTheFront = wakes { front.titleText = "npm run dev" }
        #expect(forTheFront == 1, "the front tab's title did not wake the reader of the picks")
        #expect(picks().label === front, "a shell at work in front names the workspace")
    }
}
