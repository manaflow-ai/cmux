#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileAgentChat
import CmuxMobileLinkFFI
import CmuxMobileModel
import CmuxTabsKit
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileWorkspaces

/// The chat face of a terminal tab is editable (Leo, 2026-11-22: "dont have it read only. just do it
/// properly"). Its chat is the Mac's View Only watch, which acpmux refuses a prompt, so Send types the
/// prompt into the tab's terminal (Rust `terminal_chat_prompt`) and Stop sends Escape. The toggle is a
/// key pinned beside the composer key (DEBUG builds can place it elsewhere to compare).
@MainActor @Suite(.serialized)
struct TerminalChatComposerTests {
    /// A terminal content that records what the chat face sends it.
    @MainActor final class TypingTerminal: TerminalTabContent {
        var typed: [String] = []
        var interrupted: [String] = []
        var connected = true
        var keyBarToggle: [String: TerminalChatKeySlot] = [:]
        var toggleActions: [String: @MainActor () -> Void] = [:]

        func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView { AnyView(EmptyView()) }
        func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView { AnyView(EmptyView()) }
        func submitPrompt(_ text: String, for tab: WorkspaceTab, in workspace: Workspace,
                          notSent: @escaping @MainActor () -> Void) -> Bool {
            guard connected else { return false }
            typed.append("\(tab.id): \(text)")
            return true
        }
        func interrupt(_ tab: WorkspaceTab, in workspace: Workspace) { interrupted.append(tab.id) }
        func setKeyBarChatToggle(_ slot: TerminalChatKeySlot, action: (@MainActor () -> Void)?, for tab: WorkspaceTab, in workspace: Workspace) {
            keyBarToggle[tab.id] = action == nil ? nil : slot
            toggleActions[tab.id] = action
        }
    }

    static func make(_ terminal: TypingTerminal, toggleOn: Bool = true) -> WorkspaceTabsSource {
        let backend = TerminalChatToggleTests.PairBackend(listings: [TerminalChatToggleTests.watch])
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.workspaces = [Workspace(id: "w", macID: "mac", title: "relay", directory: "~/p",
                                      tabs: [TerminalChatToggleTests.terminal("s1", agent: "claude", session: "h-1")],
                                      lastActivityAt: Date())]
        let source = WorkspaceTabsSource(store: store, workspaceID: "w", terminal: terminal, sessions: AgentSessionDirectory(),
                                         creator: WorkspaceCreator(store: store, backend: backend))
        source.terminalChatToggleOn = { toggleOn }
        return source
    }

    @Test func sendingFromTheChatFaceTypesIntoTheTerminal() throws {
        let terminal = TypingTerminal()
        let source = Self.make(terminal)
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        source.swapTerminalChat("s1", to: .chat)
        #expect(source.showsChatFace(tab, in: workspace))
        // The chat face has a composer (it was an empty bar: read only).
        let chat = try #require(source.terminalChatFaceStore(tab, in: workspace))
        chat.send(prompt: "  fix the build \n")
        #expect(terminal.typed == ["s1: fix the build"])
        #expect(chat.clientError == nil && chat.returnedDraft == nil)
        // Stop interrupts the agent in the terminal (Escape), not the watch.
        chat.cancel()
        #expect(terminal.interrupted == ["s1"])
    }

    @Test func aPromptTheTerminalCannotTakeComesBackToTheField() throws {
        let terminal = TypingTerminal()
        terminal.connected = false
        let source = Self.make(terminal)
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        let chat = try #require(source.terminalChatFaceStore(tab, in: workspace))
        chat.send(prompt: "hello")
        #expect(terminal.typed.isEmpty)
        #expect(chat.clientError == AgentChatStore.terminalNotSentNotice)
        #expect(chat.returnedDraft?.text == "hello")
        // Attachments have no terminal path: refused, the draft kept.
        terminal.connected = true
        chat.send(prompt: "look", attachments: [AgentAttachment(id: "a", kind: .image, name: "x.png", data: Data([1]))])
        #expect(terminal.typed.isEmpty)
        #expect(chat.clientError == AgentChatStore.terminalAttachmentsNotice)
    }

    @Test func theToggleIsAKeyPinnedBesideTheComposerKeyAndSwapsTheFace() throws {
        let terminal = TypingTerminal()
        let source = Self.make(terminal)
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        source.placeKeyBarChatToggle(tab, in: workspace, offered: true)
        #expect(terminal.keyBarToggle["s1"] == .pinned)
        try #require(terminal.toggleActions["s1"])()
        #expect(source.showsChatFace(tab, in: workspace))
        // The default places no second toggle in the address capsule.
        #expect(source.kitTab(tab, in: workspace).trailingAction == nil)
        // Not offered: no key.
        source.placeKeyBarChatToggle(tab, in: workspace, offered: false)
        #expect(terminal.keyBarToggle["s1"] == nil)
    }

    @Test func noToggleAndNoComposerWhenTheSettingIsOff() throws {
        let terminal = TypingTerminal()
        let source = Self.make(terminal, toggleOn: false)
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        #expect(source.kitTab(tab, in: workspace).trailingAction == nil)
        #expect(source.terminalChatFaceStore(tab, in: workspace) == nil)
    }
}
#endif
