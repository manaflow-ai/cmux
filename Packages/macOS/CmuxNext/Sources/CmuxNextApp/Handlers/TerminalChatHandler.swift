import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextWindowRules
import Foundation

/// Open Terminal as Chat (`palette.openTerminalChatView`; the palette and `cmux agent
/// open-terminal-as-chat`, so MCP's action run too): the Claude Code or Codex session the focused
/// terminal runs (`TabModel.agent`, from the daemon's agent state) opens as an agent chat tab
/// beside the terminal, resuming the same session over ACP (acpmux adopt, as Open Chat and the
/// classic import resume an outside chat). The terminal stays open: closing it would end the
/// running agent. A tab that already resumes the session is shown instead of a second one.
/// Toggle Terminal and Chat (`palette.toggleTerminalChat`) does that from the terminal (View Only:
/// the terminal keeps running it), and from the chat shows the terminal running the session it
/// resumes, else resumes the session in a new terminal in the chat's place: one action flips the two views.
enum TerminalChatHandler {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bindEffect("palette.openTerminalChatView", requires: nil, effect: { try open($0, context: context) })
        registry.bindEffect("palette.toggleTerminalChat", requires: nil, effect: { try toggle($0, context: context, watches: true) })
    }

    private static func open(_ invocation: ActionInvocation, context: AppActionContext) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: MiscHandlerStrings.noTerminal)
        }
        return try toggle(invocation, context: context)
    }

    private static func toggle(_ invocation: ActionInvocation, context: AppActionContext, watches: Bool = false) throws -> ActionEffect {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id) else {
            throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        }
        let services = context.services, tabs = services.agentTabs, terminal = tab.kind == .pty
        // A terminal's session is its agent's report (a hook's `agent_session_id`); a chat's, the outside session it adopted.
        let adopted = terminal ? nil : tabs.adoption(of: tab.id), key = adopted.map { "\($0.harness):\($0.agentSessionId)" }
        // The live terminals running a chat's session, best first (as an `agent/` link picks them).
        let terminals = adopted.map { adopted in
            DeepLink.agentTabs(harness: adopted.harness, session: adopted.agentSessionId, adopted: nil,
                               harnessSessions: services.machines.daemons.flatMap(\.store.reachableAgentHarnessSessions).filter { $0.tab != tab.id })
        } ?? []
        let handOff = key.flatMap { tabs.terminalHandOffs[$0] }
        let facts = WindowRules.ToggleFacts(terminal: terminal, chat: !terminal && tabs.isAgentTab(tab.id),
                                            agent: terminal ? tab.agent?.agent : adopted?.harness,
                                            session: terminal ? tab.agent?.harnessSessionID : adopted?.agentSessionId, running: !terminals.isEmpty,
                                            busy: tab.agentSession.map(turnOpen) ?? false,
                                            handOff: handOff, handOffOpen: handOff?.tab.map { services.locateTabOnAnyMachine($0) != nil } ?? false,
                                            now: Date().timeIntervalSince1970)
        // The route is Rust's (cmux-window-rules `tabs::terminal_chat_toggle`).
        switch WindowRules().terminalChatToggle(facts) {
        case .notAgentTab?, nil: throw ActionFailure(message: MiscHandlerStrings.terminalChatNotAgentTab)
        case .noSession?: throw ActionFailure(message: terminal ? MiscHandlerStrings.terminalChatNoSession : MiscHandlerStrings.terminalChatNoTerminal)
        case .unsupportedHarness?: throw ActionFailure(message: MiscHandlerStrings.terminalChatHarness)
        case .busy?: throw ActionFailure(message: MiscHandlerStrings.terminalChatBusy)
        case .handingOff(let made)?:
            // An earlier Toggle is resuming the session: its terminal shows, and nothing resumes it twice.
            if let made, invocation.allowsViewChange { _ = services.revealTab(made) }
            return .done
        case .resumeInTerminal(let harness, let session)?:
            return try resume(harness: harness, session: session, chat: (pane, id), tab: tab, services: services)
        case .toTerminal?:
            if let key { tabs.terminalHandOffs[key] = nil } // a terminal reports the session: any hand-off is over
            // Showing it is a view change; a headless run leaves the user's focus alone.
            guard !invocation.allowsViewChange || terminals.contains(where: { services.revealTab($0) }) else {
                throw ActionFailure(message: MiscHandlerStrings.terminalChatNoTerminal)
            }
            return .done
        case .toChat(let harness, let session)?:
            tabs.terminalHandOffs["\(harness):\(session)"] = nil // the terminal reports the session
            let adopt = AgentPaneAdopt(harness: harness, agentSessionId: session, watch: watches ? true : nil)
            // A tab that already resumes this session is shown instead of a duplicate.
            if let existing = services.agentTabs.tab(resuming: adopt) {
                if invocation.allowsViewChange { _ = services.revealTab(existing) }
                return .done
            }
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: tab.cwd, adopt: adopt))
            let pending: AgentTabPending
            do {
                pending = try services.agentTabs.open(in: pane.pane.handle, of: pane.daemon, seed: seed, adopt: adopt)
            } catch let refusal as AgentTabRefusal {
                throw ActionFailure(message: refusal.message)
            }
            // The new tab shows now; the registry reports a failed open.
            pane.selectWhenReported(surface: pending.surface)
            return .applied(result: {
                do { _ = try await pending.value(); return .success([:]) } catch is CancellationError {
                    return .success([:]) // the person closed the tab first
                } catch { return .failure(ActionWorkFailure("open terminal as chat", error)) }
            })
        }
    }

    /// Whether chat `ref` has a turn open: working, or waiting on a permission or a question.
    private static func turnOpen(_ ref: AgentSessionRef) -> Bool {
        let store = AgentTurnStateStore.shared
        return store.state(for: ref) == .needsInput || store.isWorking(ref, isChatMachine: { _ in false })
    }

    /// A chat no terminal runs: its acpmux run stops (the transcript kept), the harness's resume
    /// command opens the session in a new terminal beside it, and the chat closes, so Toggle goes
    /// back and forth both ways (Leo, 2026-11-12: "that's the whole joy of the thing").
    private static func resume(harness: String, session: String, chat: (pane: PaneController, id: StripTabID), tab: TabModel,
                               services: AppServices) throws -> ActionEffect {
        let tabs = services.agentTabs, key = "\(harness):\(session)"
        guard let command = AgentResume.command(provider: harness, sessionID: session), let acpmux = QuitAgents.environment(services),
              let run = tabs.session(of: tab.id) else { throw ActionFailure(message: MiscHandlerStrings.terminalChatStopFailed) }
        let cwd = tabs.existingView(tab.id)?.model.transport.sessions.folder(of: run) ?? tab.cwd
        let workspace = chat.pane.daemon.store.workspace(containing: chat.pane.pane.handle)?.id
        // Until the terminal's hooks report the session, a second Toggle shows it instead of resuming again.
        tabs.terminalHandOffs[key] = WindowRules.HandOff(deadline: Date().timeIntervalSince1970 + 60)
        // action-wait-allow: acpmux must end the chat's run before the harness resumes its session; nothing can show first
        return .waiting(.externalProcess) {
            @MainActor func fail(_ reason: String) -> ActionWorkFailure {
                tabs.terminalHandOffs[key] = nil
                return ActionWorkFailure(refusal: .unavailable, reason: reason)
            }
            // A prompt sent since the click is a turn too: it is never cut off.
            if tab.agentSession.map(turnOpen) == true { return fail(MiscHandlerStrings.terminalChatBusy) }
            do { try await acpmux.stopSession(id: run) } catch { return fail(MiscHandlerStrings.terminalChatStopFailed) }
            // The chat's pane, else its workspace's focused one when the pane closed meanwhile.
            guard let target = services.paneController(for: chat.pane.pane)
                ?? workspace.flatMap({ services.windows.reveal(workspaceID: $0)?.focusedPane }) else { return fail(MiscHandlerStrings.terminalChatNoPane) }
            let work = services.registry.capturingWork {
                // A `then` replaces Home's dock placement, so it places the tab too.
                target.newTerminalTab(cwd: cwd, typing: command + "\r", placementOwner: HomeDockOpens.opensBeside(target.pane, services: services),
                                      then: HomeDockOpens.placing(target.pane, services: services, focus: true, then: { surface in
                    // The terminal stands for the session now; the stopped chat closes and no longer resumes it.
                    if let made = target.daemon.store.tab(surface: surface) { tabs.terminalHandOffs[key]?.tab = made.id }
                    tabs.adoptions[key] = nil
                    services.paneController(for: chat.pane.pane)?.close([chat.id])
                }))
            }
            for task in work { if let failure = await task.value { tabs.terminalHandOffs[key] = nil; return failure } }
            return work.isEmpty ? fail(MiscHandlerStrings.terminalChatNoPane) : nil
        }
    }
}
