import CmuxNextAgentActivity
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPalette
import Foundation
import Testing

/// Cmd-P finds a Chief subagent's workspace by its short id (Lawrence 2026-10-23, msg 11943).
/// The Chief names each subagent's acpmux session `optchat-sub-<home>-a<N>` and opens its
/// workspace with that session's chat tab, so the chat tab is where the workspace's id is
/// stored: every subagent workspace whose chat is still in the Chief's acpmux has it, the
/// older ones too. An older Chief put the id in front of the workspace name (`a345 · task`).
/// Agent chat rows read as their chat, never as the `about:blank` their records carry.
@MainActor
struct PaletteSubagentIDTests {
    private static let chief = "chief:2e448bc2"

    private static func lane(_ id: String, _ name: String) -> AgentActivityLane {
        AgentActivityLane(id: id, name: name, title: name, peer: nil, parent: "optchat-chief:2e448bc2",
                          state: .idle, since: nil, error: nil, harness: "claude")
    }

    private static let ids = ChiefSubagentIDs(lanes: [
        "s612": lane("s612", "optchat-sub-2e448bc2-a612"),
        "s7": lane("s7", "optchat-sub-2e448bc2-a7-2"),
        "peer": lane("peer", "chief-subagents-2/optchat-sub-2e448bc2-a601"),
        "turn": lane("turn", "optchat-2e448bc2-14"),
        "mine": lane("mine", "claude-sr-2"),
    ])

    @Test func aSubagentsChatTabNamesItsWorkspace() {
        let chat = AgentSessionRef(host: Self.chief, session: "s612", harness: "claude")
        #expect(Self.ids.id(name: "Markdown pane omnibar back", chats: [chat]) == "a612")
        #expect(Self.ids.id(name: "x", chats: [AgentSessionRef(host: Self.chief, session: "s7")]) == "a7",
                "acpmux's -2 dedupe suffix is not part of the id")
        #expect(Self.ids.id(name: "x", chats: [AgentSessionRef(host: Self.chief, session: "peer")]) == "a601",
                "a cloud subagent's session is named under its peer")
    }

    @Test func otherChatsNameNoSubagent() {
        #expect(Self.ids.id(name: "cmux", chats: [AgentSessionRef(host: Self.chief, session: "turn")]) == nil)
        #expect(Self.ids.id(name: "cmux", chats: [AgentSessionRef(host: "install:me", session: "mine")]) == nil)
        #expect(Self.ids.id(name: "cmux", chats: [AgentSessionRef(host: Self.chief, session: "gone")]) == nil)
        #expect(Self.ids.id(name: "cmux", chats: [AgentSessionRef(host: Self.chief)]) == nil)
    }

    @Test func anOlderChiefsWorkspaceNameCarriesItsID() {
        #expect(Self.ids.id(name: "a212 · Chief agents", chats: []) == "a212")
        #expect(Self.ids.id(name: "a6 parity", chats: []) == nil)
        #expect(Self.ids.id(name: "a · b", chats: []) == nil)
    }

    @Test func anAgentChatRowReadsAsItsChatNotAboutBlank() {
        let entries = [
            PaletteNavigationEntry(id: "chat", kind: .tab(.agentChat), title: "about:blank", workspaceTitle: "Cmd-T tabs self-close"),
            PaletteNavigationEntry(id: "empty", kind: .tab(.agentChat), title: "", workspaceTitle: "w"),
            PaletteNavigationEntry(id: "web", kind: .tab(.browser), title: "about:blank", workspaceTitle: "w"),
            PaletteNavigationEntry(id: "shell", kind: .tab(.terminal), title: "zsh", workspaceTitle: "w"),
        ]
        let titled = PaletteNavigationEntries.titled(entries) { entry in
            ["chat": "Fix the tab close race", "empty": "Empty chat", "web": "New Tab", "shell": "never asked"][entry.id]
        }
        #expect(titled.map(\.title) == ["Fix the tab close race", "Empty chat", "New Tab", "zsh"])
    }
}
