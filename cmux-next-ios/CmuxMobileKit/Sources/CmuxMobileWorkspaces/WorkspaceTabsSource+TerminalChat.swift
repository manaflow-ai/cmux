#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileLinkFFI
import CmuxMobileModel
import CmuxSpinner
import CmuxTabsKit
import OSLog
import SwiftUI

private let terminalChatLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal-chat")

/// Toggle Terminal and Chat on the phone (Leo, 2026-11-12: terminal and GUI are two live views
/// of one harness session, instant both ways, mid-turn). A terminal opens on its terminal face
/// until the person picks Chat (Leo, 2026-11-15).
///
/// A terminal tab whose agent is Claude Code or Codex has two faces: its terminal and a View
/// Only chat of the session its agent runs (the chat the Mac's Toggle opens, acpmux `watch`).
/// Both stay built while the tab is open (`TerminalChatPair`), so a swap is a flag flip: no
/// reload, the chat's scroll kept. The page menu's Show Chat / Show Terminal row swaps them.
///
/// Every decision (which faces a tab offers and opens on, what a tap does, which chat shows a
/// session) is Rust's: cmux-mobile-link-ffi `terminal_chat.rs`, over the Mac's own route
/// (`cmux-window-rules` `tabs::terminal_chat_toggle`). This file reads the facts and binds.
extension WorkspaceTabsSource {
    var terminalChatBackend: (any TerminalChatBackend)? { creator?.backend as? any TerminalChatBackend }

    /// The Mac's chats the pairing reads (observed: a chat the Mac opens shows here).
    private func terminalChatCandidates(_ macID: String) -> [TerminalChatCandidate] {
        (terminalChatBackend?.terminalChatListings(on: macID) ?? []).map {
            TerminalChatCandidate(sessionId: $0.sessionID, harness: $0.harness, agentSessionId: $0.agentSessionID,
                                  watching: $0.watching, status: $0.status)
        }
    }

    /// Each part escaped (`\` to `\\`, `|` to `\|`), so an id that holds a `|` never makes two keys one.
    private static func openKey(_ macID: String, _ harness: String, _ session: String) -> String {
        [macID, harness, session]
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }
            .joined(separator: "|")
    }

    /// The acpmux chat that shows terminal `tab`'s session: one of the Mac's (a View Only chat
    /// first), else the one this phone had opened, else the one this phone kept on disk (a
    /// relaunch with the Mac out of reach opens on its kept turns). Rust decides
    /// (`terminal_chat_pairing`), with whether to keep or forget the pairing.
    func chatPairing(_ tab: WorkspaceTab, in workspace: Workspace) -> TerminalChatPairing? {
        guard tab.kind == .terminal, let harness = tab.harness, let session = tab.linkIDs?.harnessSession else { return nil }
        // The family (`claude-code` is `claude`), as `openTerminalChatIfNeeded` keys what it opens.
        let family = terminalChatHarness(agent: harness) ?? harness
        let backend = terminalChatBackend
        return terminalChatPairing(chats: terminalChatCandidates(workspace.macID),
                                   listedWhole: backend?.terminalChatListedWhole(on: workspace.macID) ?? false,
                                   harness: harness, session: session,
                                   opened: openedTerminalChats[Self.openKey(workspace.macID, family, session)],
                                   kept: backend?.keptTerminalChat(harness: family, session: session, on: workspace.macID))
    }

    func terminalChatSessionID(_ tab: WorkspaceTab, in workspace: Workspace) -> String? {
        chatPairing(tab, in: workspace)?.chat
    }

    /// `tab`'s facts, as Rust reads them.
    func terminalChatFacts(_ tab: WorkspaceTab, in workspace: Workspace) -> TerminalChatFacts {
        switch tab.kind {
        case .terminal:
            let refused = terminalChatRefusingMacs.contains(workspace.macID) && terminalChatSessionID(tab, in: workspace) == nil
            return TerminalChatFacts(terminal: true, chat: false, agent: tab.harness, session: tab.linkIDs?.harnessSession,
                                     running: false, chatRefused: refused)
        case .agent:
            let listing = tab.linkIDs?.agentSession.flatMap { id in
                terminalChatBackend?.terminalChatListings(on: workspace.macID).first { $0.sessionID == id }
            }
            let harness = listing?.harness ?? tab.harness
            let session = listing?.agentSessionID
            return TerminalChatFacts(terminal: false, chat: true, agent: harness, session: session,
                                     running: session.flatMap { terminalTab(running: $0, harness: harness, on: workspace.macID) } != nil,
                                     chatRefused: false)
        case .browser, .simulator:
            return TerminalChatFacts(terminal: false, chat: false, agent: nil, session: nil, running: false, chatRefused: false)
        }
    }

    func pairFaces(_ tab: WorkspaceTab, in workspace: Workspace) -> TerminalChatFaces {
        terminalChatFaces(facts: terminalChatFacts(tab, in: workspace))
    }

    /// The face `tab` shows: the person's choice while it is enabled, else Rust's default.
    func face(of tab: WorkspaceTab, faces: TerminalChatFaces) -> TabFace {
        guard faces.offered, let chosen = chosenFaces[tab.id] else { return faces.defaultFace }
        switch chosen {
        case .chat: return faces.chatEnabled ? .chat : faces.defaultFace
        case .terminal: return faces.terminalEnabled ? .terminal : faces.defaultFace
        }
    }

    /// The terminal tab (with its workspace) whose agent reports `session` under `harness`, on Mac `macID`.
    func terminalTab(running session: String, harness: String?, on macID: String) -> (Workspace, WorkspaceTab)? {
        for workspace in store.workspaces where workspace.macID == macID {
            for tab in workspace.tabs where tab.kind == .terminal && tab.linkIDs?.harnessSession == session {
                // The same harness, as Rust names it (`claude-code` and `claude-cr` are Claude).
                let faces = pairFaces(tab, in: workspace)
                let wanted = harness.flatMap({ terminalChatHarness(agent: $0) })
                if faces.offered, harness == nil || faces.harness == wanted { return (workspace, tab) }
            }
        }
        return nil
    }

    /// The chat face's store of terminal `tab`: the acpmux chat `chatSession`, keyed apart from the
    /// tab's own id so a new chat of the tab is a new store.
    func terminalChatStore(_ tab: WorkspaceTab, in workspace: Workspace, chatSession: String, faces: TerminalChatFaces) -> AgentChatStore {
        let harness = faces.harness ?? tab.harness ?? "claude"
        return sessions.store(for: AgentSessionSummary(
            id: "\(tab.id)#chat:\(chatSession)", name: tab.title, harness: harness,
            agentName: harness == "codex" ? "Codex" : "Claude", cwd: tab.subtitle ?? workspace.directory,
            workspaceTitle: workspace.title, macName: macName, branch: workspace.branch,
            status: tab.agentStatus.map { $0 == .waiting ? .waiting : .running } ?? .idle,
            macID: workspace.macID, acpmuxSessionID: chatSession))
    }

    /// The chat face needs a chat no chat of the Mac is: ask the Mac for its View Only chat, once
    /// per session. A Mac that refuses a phone this (acpmux `remote.adopt_refused`) is not asked
    /// again; its terminals open on the terminal face, their chat face disabled with why.
    ///
    /// Also keeps the pairing on disk once a chat shows the session (or forgets a stale one), so
    /// a relaunch with the Mac out of reach opens on that chat's kept turns.
    func openTerminalChatIfNeeded(_ tabID: String) {
        guard let workspace, let tab = workspaceTab(tabID), tab.kind == .terminal,
              let session = tab.linkIDs?.harnessSession, let backend = terminalChatBackend else { return }
        let faces = pairFaces(tab, in: workspace)
        guard faces.offered, let harness = faces.harness else { return }
        let macID = workspace.macID
        let pairing = chatPairing(tab, in: workspace)
        if let pairing, pairing.keep || pairing.forget {
            backend.keepTerminalChat(pairing.keep ? pairing.chat : nil, harness: harness, session: session, on: macID)
        }
        guard faces.chatEnabled, pairing?.chat == nil, !terminalChatRefusingMacs.contains(macID) else { return }
        let key = Self.openKey(macID, harness, session)
        guard openingTerminalChats.insert(key).inserted else { return }
        guard backend.keptTerminalChatsLoaded else {
            // The kept pairings are read off the main thread at launch; until the read lands a kept
            // chat looks missing, and asking a Mac out of reach would drop the tab to its terminal.
            // Wait for the read, then decide again.
            Task { @MainActor [weak self] in
                await backend.loadKeptTerminalChats()
                self?.openingTerminalChats.remove(key)
                self?.openTerminalChatIfNeeded(tabID)
            }
            return
        }
        Task { @MainActor [weak self] in
            defer { self?.openingTerminalChats.remove(key) }
            do {
                switch try await backend.openTerminalChat(harness: harness, session: session, terminalTabID: tabID, on: macID) {
                case .chat(let chat):
                    self?.openedTerminalChats[key] = chat
                    backend.keepTerminalChat(chat, harness: harness, session: session, on: macID)
                case .refused:
                    terminalChatLog.info("acpmux on \(macID, privacy: .public) makes no View Only chat for a phone")
                    self?.terminalChatRefusingMacs.insert(macID)
                }
            } catch {
                // The terminal stays reachable: the tab falls back to it, and says why.
                guard let self else { return }
                terminalChatLog.error("view only chat failed: \(String(describing: error), privacy: .public)")
                if self.chosenFaces[tabID] != .terminal { self.chosenFaces[tabID] = .terminal }
                self.show(Self.message(error))
            }
        }
    }

    /// A tap on face `to` of tab `tabID` (the page menu's Show Chat / Show Terminal row).
    // perf-hot: 100ms ios-terminal-chat-swap
    func swapTerminalChat(_ tabID: String, to: TabFace) {
        guard let workspace, let tab = workspaceTab(tabID) else { return }
        let facts = terminalChatFacts(tab, in: workspace)
        let shown = face(of: tab, faces: terminalChatFaces(facts: facts))
        switch terminalChatSwap(facts: facts, shown: shown, to: to) {
        case .stay:
            return
        case .show(let face):
            ConnectTimeline.shared.event("terminal_chat_swap", detail: face == .chat ? "chat" : "terminal")
            chosenFaces[tabID] = face
            if face == .terminal { terminal.focusInput(for: tab, in: workspace) }
            CmuxMobileTheme.standard.haptics.selection()
        case .revealTerminal(let harness, let session):
            guard let found = terminalTab(running: session, harness: harness, on: workspace.macID) else {
                show("The terminal running this chat closed.")
                return
            }
            let (home, running) = found
            chosenFaces[running.id] = .terminal
            if home.id == workspace.id {
                activate(running.id)
            } else {
                // Another workspace: it opens on that terminal next time it shows.
                store.requestOpen(tabID: running.id, in: home.id)
                show("The terminal running this chat is in \u{201C}\(home.title)\u{201D}.")
            }
        case .unavailable(let reason):
            show(reason)
            CmuxMobileTheme.standard.haptics.error()
        }
    }

    /// The page menu's row on half of a pair (as the Mac's tab right-click offers it).
    func terminalChatItems(_ tab: WorkspaceTab, in workspace: Workspace) -> [TabsKitMenuItem] {
        let faces = pairFaces(tab, in: workspace)
        guard faces.offered else { return [] }
        let other: TabFace = face(of: tab, faces: faces) == .chat ? .terminal : .chat
        return [TabsKitMenuItem(id: "tab.toggleTerminalChat", title: other == .chat ? "Show Chat" : "Show Terminal",
                                systemImage: other == .chat ? "bubble.left" : "terminal") { [weak self] in
            self?.swapTerminalChat(tab.id, to: other)
        }]
    }

    /// Whether terminal `tab` shows its chat face now (its key bar and keyboard stay away then).
    func showsChatFace(_ tab: WorkspaceTab, in workspace: Workspace) -> Bool {
        guard tab.kind == .terminal else { return false }
        let faces = pairFaces(tab, in: workspace)
        return faces.offered && face(of: tab, faces: faces) == .chat
    }
}

/// A terminal tab's two faces, both kept built: the terminal and, once a chat shows its
/// session, the chat. A swap changes which one is visible and takes touches; neither
/// reloads, so the chat keeps its scroll and the terminal its grid (as the Mac parks both
/// views of a pair in its pane).
struct TerminalChatPair<Terminal: View, Chat: View>: View {
    let showsChat: Bool
    @ViewBuilder let terminal: Terminal
    @ViewBuilder let chat: Chat

    var body: some View {
        ZStack {
            terminal
                .opacity(showsChat ? 0 : 1)
                .allowsHitTesting(!showsChat)
                .accessibilityHidden(showsChat)
            chat
                .opacity(showsChat ? 1 : 0)
                .allowsHitTesting(showsChat)
                .accessibilityHidden(!showsChat)
        }
    }
}

/// A terminal tab's page with its chat face (`WorkspaceTabPage`): the pair and the one request a
/// chat face may need (`openTerminalChatIfNeeded`). The page menu's Show Chat / Show Terminal row
/// swaps the faces; the page has no floating Chat | Terminal control (Aziz, 2026-11-16).
struct TerminalChatPage<Terminal: View>: View {
    let source: WorkspaceTabsSource
    let tab: WorkspaceTab
    let workspace: Workspace
    let topInset: CGFloat
    let reportScroll: (CGFloat) -> Void
    @ViewBuilder let terminal: Terminal

    var body: some View {
        let faces = source.pairFaces(tab, in: workspace)
        let showsChat = faces.offered && source.face(of: tab, faces: faces) == .chat
        let chatSession = faces.offered ? source.terminalChatSessionID(tab, in: workspace) : nil
        TerminalChatPair(showsChat: showsChat) {
            terminal
        } chat: {
            if faces.offered, faces.chatEnabled {
                if let chatSession {
                    AgentChatTranscript(
                        store: source.terminalChatStore(tab, in: workspace, chatSession: chatSession, faces: faces),
                        surface: source.surface("\(tab.id)#chat"), topInset: topInset + 8, onUserScroll: reportScroll)
                        .background(Color.cmuxMobileBackground)
                } else {
                    CmuxSpinner(label: Text("Opening chat…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.cmuxMobileBackground)
                }
            }
        }
        // Runs again when another chat shows the session, so the pairing kept on disk follows it.
        .task(id: "\(tab.linkIDs?.harnessSession ?? "")|\(faces.offered)|\(chatSession ?? "")") {
            if faces.offered { source.openTerminalChatIfNeeded(tab.id) }
        }
    }
}
#endif
