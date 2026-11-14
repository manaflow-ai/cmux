#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Toggle Terminal and Chat on the phone (Leo, 2026-11-12: terminal and GUI are two live views of one
/// harness session, instant both ways; on iOS chat is the default for Claude Code and Codex). The
/// decisions are Rust's (cmux-mobile-link-ffi `terminal_chat.rs`); these check the binding: the facts
/// the tab source reads, the face it shows and what a tap on the control does.
@MainActor @Suite(.serialized)
struct TerminalChatToggleTests {
    /// A Mac whose acpmux lists `listings`, and that answers a View Only chat request with `answer`.
    @MainActor final class PairBackend: WorkspaceCreationBackend, TerminalChatBackend {
        var listings: [TerminalChatListing]
        var answer: TerminalChatOpen
        var asked: [String] = []
        init(listings: [TerminalChatListing] = [], answer: TerminalChatOpen = .refused) {
            self.listings = listings
            self.answer = answer
        }
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func terminalChatListings(on macID: String) -> [TerminalChatListing] { listings }
        func openTerminalChat(harness: String, session: String, terminalTabID: String, on macID: String) async throws -> TerminalChatOpen {
            asked.append("\(harness) \(session) \(terminalTabID)")
            return answer
        }
    }

    static func terminal(_ id: String, agent: String?, session: String?) -> WorkspaceTab {
        var tab = WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: "~/p", harness: agent)
        tab.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_\(id)", harnessSession: session)
        return tab
    }

    static func chat(_ id: String, session: String) -> WorkspaceTab {
        var tab = WorkspaceTab(id: id, kind: .agent, title: "Claude", harness: "claude")
        tab.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_\(id)", agentSession: session)
        return tab
    }

    static func make(_ backend: PairBackend, tabs: [WorkspaceTab]) -> (AppStore, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.workspaces = [Workspace(id: "w", macID: "mac", title: "relay", directory: "~/p", tabs: tabs, lastActivityAt: Date())]
        let source = WorkspaceTabsSource(store: store, workspaceID: "w", creator: WorkspaceCreator(store: store, backend: backend))
        return (store, source)
    }

    static func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    static let watch = TerminalChatListing(sessionID: "a-1", harness: "claude", agentSessionID: "h-1", watching: true, status: "idle")

    @Test func aClaudeTerminalOpensOnItsChatAndSwapsBothWaysInPlace() throws {
        let backend = PairBackend(listings: [Self.watch])
        let (_, source) = Self.make(backend, tabs: [Self.terminal("s1", agent: "claude-code", session: "h-1")])
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        #expect(source.pairFaces(tab, in: workspace).offered)
        // Chat is the default face, on the Mac's View Only chat of the session: nothing to ask for.
        #expect(source.showsChatFace(tab, in: workspace))
        #expect(source.terminalChatSessionID(tab, in: workspace) == "a-1")
        source.openTerminalChatIfNeeded("s1")
        #expect(backend.asked.isEmpty)
        // Both ways, the same tab: a face flag, no new tab, no request.
        source.swapTerminalChat("s1", to: .terminal)
        #expect(!source.showsChatFace(tab, in: workspace))
        source.swapTerminalChat("s1", to: .chat)
        #expect(source.showsChatFace(tab, in: workspace))
        #expect(source.activeTabID == "s1")
        // The page menu's row is the other face.
        #expect(source.terminalChatItems(tab, in: workspace).map(\.title) == ["Show Terminal"])
    }

    @Test func aTerminalWithNoChatAsksTheMacForTheViewOnlyChatOnce() async throws {
        let backend = PairBackend(answer: .chat("w-9"))
        let (_, source) = Self.make(backend, tabs: [Self.terminal("s1", agent: "codex", session: "h-2")])
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        source.openTerminalChatIfNeeded("s1")
        source.openTerminalChatIfNeeded("s1")
        await Self.settle { source.terminalChatSessionID(tab, in: workspace) != nil }
        #expect(backend.asked == ["codex h-2 s1"])
        #expect(source.terminalChatSessionID(tab, in: workspace) == "w-9")
        #expect(source.showsChatFace(tab, in: workspace))
    }

    @Test func aMacThatRefusesAPhoneAViewOnlyChatLeavesTheTerminalAndSaysWhy() async throws {
        let backend = PairBackend(answer: .refused)
        let (_, source) = Self.make(backend, tabs: [Self.terminal("s1", agent: "claude", session: "h-3"),
                                                    Self.terminal("s2", agent: "claude", session: "h-4")])
        let workspace = try #require(source.workspace)
        let tab = try #require(source.workspaceTab("s1"))
        source.openTerminalChatIfNeeded("s1")
        await Self.settle { source.terminalChatRefusingMacs.contains("mac") }
        let faces = source.pairFaces(tab, in: workspace)
        #expect(faces.offered && !faces.chatEnabled && faces.defaultFace == .terminal)
        #expect(!source.showsChatFace(tab, in: workspace))
        source.swapTerminalChat("s1", to: .chat)
        #expect(source.toastText == faces.disabledReason)
        // The Mac is not asked again, for this terminal or another.
        source.openTerminalChatIfNeeded("s2")
        await Self.settle { false }
        #expect(backend.asked.count == 1)
        // Once the Mac opens the chat (its own Toggle), the chat face is back.
        backend.listings = [TerminalChatListing(sessionID: "a-3", harness: "claude", agentSessionID: "h-3", watching: true, status: "idle")]
        #expect(source.pairFaces(tab, in: workspace).chatEnabled)
        #expect(source.showsChatFace(tab, in: workspace))
    }

    @Test func aChatOfATerminalsSessionRevealsThatTerminal() throws {
        let backend = PairBackend(listings: [Self.watch])
        let (_, source) = Self.make(backend, tabs: [Self.chat("c1", session: "a-1"), Self.terminal("s1", agent: "claude", session: "h-1")])
        let workspace = try #require(source.workspace)
        let chat = try #require(source.workspaceTab("c1"))
        let terminal = try #require(source.workspaceTab("s1"))
        let faces = source.pairFaces(chat, in: workspace)
        #expect(faces.offered && faces.terminalEnabled)
        source.activate("c1")
        source.swapTerminalChat("c1", to: .terminal)
        #expect(source.activeTabID == "s1")
        #expect(!source.showsChatFace(terminal, in: workspace))
    }

    @Test func aChatNoTerminalRunsKeepsItsTerminalFaceDisabled() throws {
        let backend = PairBackend(listings: [Self.watch])
        let (_, source) = Self.make(backend, tabs: [Self.chat("c1", session: "a-1")])
        let workspace = try #require(source.workspace)
        let chat = try #require(source.workspaceTab("c1"))
        let faces = source.pairFaces(chat, in: workspace)
        #expect(faces.offered && !faces.terminalEnabled)
        source.activate("c1")
        source.swapTerminalChat("c1", to: .terminal)
        #expect(source.activeTabID == "c1")
        #expect(source.toastText == faces.disabledReason)
    }

    @Test func aPlainTerminalOrAnAgentAcpmuxCannotAdoptHasNoControl() throws {
        let backend = PairBackend(listings: [Self.watch])
        let (_, source) = Self.make(backend, tabs: [Self.terminal("s1", agent: nil, session: nil),
                                                    Self.terminal("s2", agent: "opencode", session: "h-1")])
        let workspace = try #require(source.workspace)
        for id in ["s1", "s2"] {
            let tab = try #require(source.workspaceTab(id))
            #expect(!source.pairFaces(tab, in: workspace).offered)
            #expect(!source.showsChatFace(tab, in: workspace))
            #expect(source.terminalChatItems(tab, in: workspace).isEmpty)
        }
    }
}
#endif
