import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextPages
import CmuxNextTerminal
import CmuxNextTerminalComments
import CmuxNextWindowRules
import Foundation

/// Terminal actions: clipboard, selection, find, clear and reset, font size
/// and scrolling (Ghostty binding actions on the live surface), and input
/// sent through the daemon (works for tabs no window shows).
enum TerminalHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindClipboard(registry, ctx)
        bindSurfaceBindings(registry, ctx)
        TerminalHandlers.bindFind(into: registry, context: ctx)
        TerminalHandlers.bindInput(into: registry, context: ctx)
        bindKeep(registry, ctx)
        bindPinTail(registry, ctx)
        bindCopyMode(registry, ctx)
        TextBoxHandlers.bind(into: registry, context: ctx)
        bindComments(into: registry, context: ctx)
    }

    /// Runs a Ghostty binding action on the targeted or focused terminal.
    static func perform(_ binding: String, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let entry = ctx.terminal(invocation) else { return }
        if !entry.session.surfaceView.performBindingAction(binding) {
            ctx.refuse(RefusalStrings.ghosttyRejected(String(describing: binding)))
        }
    }

    static func selection(of entry: TerminalEntry) -> String? {
        entry.session.surfaceView.accessibilitySelectedText().flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func bindClipboard(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("terminalCopy", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            // Cmd-C with nothing selected goes to the program (`TerminalSurfaceView.copy`, as in
            // Ghostty and the shipping cmux); a menu, palette or CLI Copy with nothing selected refuses.
            guard entry.session.surfaceView.hasSelection || registry.isDispatchingKeyDown() else {
                return ctx.refuse(RefusalStrings.nothingSelected)
            }
            entry.session.surfaceView.copy(nil)
        })
        registry.bind("terminalPaste", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            entry.session.surfaceView.paste(nil)
        })
        registry.bind("terminal.selectAll", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            entry.session.surfaceView.selectAll(nil)
        })
    }

    private static func bindSurfaceBindings(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        // The actions that run one Ghostty binding action: Rust's table (`tabs::panes::TERMINAL_BINDINGS`).
        for (id, binding) in WindowRules().terminalBindings() {
            registry.bind(ActionID(rawValue: id), invoke: { perform(binding, $0, ctx) })
        }
        // Cmd-K (decision K1): the daemon owns the terminal state, so the clear happens there and
        // reaches every view; Ghostty's clear_screen on the app's mirror alone is undone by the
        // next frame and comes back on reattach. On the alternate screen a key press goes to the
        // program as Cmd-K, encoded by the daemon with its keyboard modes (Ghostty's
        // `performable:clear_screen`; Claude Code clears its screen on it).
        registry.bind("terminal.clear", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            if tab.kind == .remoteTerminal { return clearRemoteTerminal(tab, ctx) }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            let request = ClearHistoryRequest(surface: tab.surface,
                                              fallbackKey: registry.isDispatchingKeyDown() ? .command("k") : nil)
            clear(on: ctx.services.activeDaemon, ctx) { _ = try await $0.request(request) }
        })
        registry.bind("reconnectPane", invoke: { invocation in
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            guard case .terminal = content, let key = pane.currentTabKey else { return ctx.refuse(RefusalStrings.notATerminal) }
            ctx.services.cache.release(key)
            pane.showSelected()
            pane.focusContent(source: .programmatic)
        })
    }

    /// Cmd-K on a remote-terminal tab: the terminal's own session clears it
    /// (by its public id; that session has no tab for it) and this view follows.
    private static func clearRemoteTerminal(_ tab: TabModel, _ ctx: AppActionContext) {
        let services = ctx.services
        guard let ref = tab.remote, let daemon = services.machines.daemon(session: ref.sessionID) else {
            return ctx.refuse(RemoteStrings.noMachine)
        }
        guard let terminal = services.remoteTerminals.resource(for: ref, on: daemon) else {
            return ctx.refuse(RemoteStrings.machineHasNoTerminal)
        }
        clear(on: daemon, ctx) { try await $0.clearTerminalHistory(terminal) }
    }

    /// Sends a Cmd-K clear. A refusal changes nothing on screen, so it is never
    /// only logged: it goes to the crash telemetry as a non-fatal failure, which
    /// keeps a silent no-op Cmd-K visible (cx-6so.55).
    private static func clear(on daemon: DaemonService, _ ctx: AppActionContext,
                              _ body: @escaping DaemonCommandBody) {
        guard daemon.connection != nil else { return ctx.refuse(MiscHandlerStrings.daemonOffline) }
        let reporter = ctx.services.crashReporting.reporter
        daemon.send("clear-history", onFailure: { failure in
            // An alternate-screen program without Kitty keys has no Cmd-K: nothing changed, as in Ghostty.
            if failure.message.contains(ClearHistoryRequest.fallbackUnrepresentable) { return }
            // A typed refusal (a pane still opening) is not a failure to report: the person was told why.
            if failure.refusal != nil { return }
            reporter.recordFailure("terminal.clear", message: Self.failureKind(failure.message))
        }, body)
    }

    /// The daemon's refusal reason without user content (no paths or screen text): Rust's `tabs::panes::clear_failure_kind`.
    static func failureKind(_ message: String) -> String {
        WindowRules().clearFailureKind(message)
    }

    /// `terminal keep [--on false]`: the tab's terminal outlives its last
    /// tab (`terminal-reap-v1`); off lets the daemon end it after the reap
    /// grace period once no tab shows it.
    private static func bindKeep(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("terminal.keep", unavailable: ctx.needs(DaemonCapability.terminalReap.rawValue), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            let keep = invocation["on"]?.boolValue ?? true, surface = tab.surface
            ctx.send("set-terminal-keep") { _ = try await $0.setTerminalKeep(.surface(surface), keep: keep) }
        })
    }

    /// Show Last Line in Sidebar, `terminal pin-tail on|off`: the tab's terminal's last output line
    /// under its workspace in the sidebar (`terminal-tail-pin-v1`); off clears it.
    private static func bindPinTail(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bindEffect("terminal.pinTail", unavailable: ctx.needs(DaemonCapability.terminalTailPin.rawValue), effect: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return .done }
            guard tab.kind == .pty else { return .refused(RefusalStrings.notATerminal) }
            guard let connection = ctx.connection() else { return .done }
            let pinned = invocation["on"]?.boolValue ?? true, surface = tab.surface
            // action-wait-allow: the pin lives only in the daemon's terminal, which draws the line; the app keeps no copy to show first
            return .waiting(.daemonEcho) {
                do { _ = try await connection.setTerminalTailPin(.surface(surface), pinned: pinned); return nil } catch { return ActionWorkFailure("set-terminal-tail-pin", error) }
            }
        })
    }

    /// Vim-style keyboard copy mode over the scrollback (⇧⌘M); the terminal
    /// view takes the keys until Esc, q, or a copy.
    private static func bindCopyMode(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("toggleTerminalCopyMode", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            if !entry.session.surfaceView.toggleCopyMode() { ctx.refuse(RefusalStrings.ghosttyRejected("keyboard_copy_cursor_set")) }
        })
        ActionTargetTitles.setPaletteState("toggleTerminalCopyMode", in: registry) {
            if case .terminal(let entry)? = ctx.services.windows.active?.focusedPane?.currentContent { entry.session.surfaceView.isCopyModeActive } else { false }
        }
    }
}

/// Comment… on a terminal selection (`terminal.sendSelectionToChat`, diff-comments-threads-v1): the cmux
/// comment dialog takes a comment on the selected text, and Add to Chat saves it on the chat's
/// session host as a terminal comment and sends it to the workspace's agent chat (the one design
/// mode sends to) with `keep: true`, so it stays as a thread whose reply shows in a card over the
/// terminal (``TerminalCommentThreads``). Without diff-comments-threads-v1 the row stays the placeholder
/// (``TerminalToChatPlaceholders``): out of the menus and refused with its reason.
extension TerminalHandlers {
    static func bindComments(into registry: ActionRegistry, context ctx: AppActionContext) {
        let id: ActionID = "terminal.sendSelectionToChat"
        let threads = TerminalCommentThreads(terminal: { ctx.services.cache.existingTerminal($0)?.session }, refuse: { ctx.refuse($0) })
        registry.bindEffect(id, effect: { invocation in
            guard invocation.isPersonsOwnRun else { return .refused(TerminalCommentStrings.gesture) }
            let (found, reason) = commentTarget(invocation, ctx)
            guard let target = found else { return .refused(reason ?? TerminalToChatPlaceholders.reason) }
            guard let entry = ctx.terminal(invocation) else { return .done }
            guard let quote = selection(of: entry) else { return .refused(RefusalStrings.nothingSelected) }
            let anchor = entry.session.surfaceView, rows = entry.session.commentAnchorRows()
            guard let window = anchor.window else { return .refused(RefusalStrings.notATerminal) }
            // ChatQuote titles a source by its last path component; a terminal title is not a path.
            let title = (target.terminal.title ?? "").isEmpty ? TerminalCommentStrings.terminal : target.terminal.title ?? ""
            ViewerCommentPrompt(quote: ChatQuote(source: title.replacingOccurrences(of: "/", with: "\u{2215}"), kind: .code, quoted: quote))
                .run(in: window) { commented in
                    threads.send(commented.comment, quote: quote, rows: rows, to: target, anchor: anchor, failed: { ctx.refuse($0) })
                }
            return .done
        })
        ActionTargetVisibility.gate(id, in: registry, reason: { commentTarget($0, ctx).refusal })
        ActionTargetTitles.set(id, in: registry) { _ in TerminalCommentStrings.menuTitle }
    }

    /// The terminal `invocation` names, the workspace chat it sends to and that chat's session host
    /// (which must keep threads; Labs `labs.commentThreads` on), else why not. Reads no live view, so a menu can ask it.
    static func commentTarget(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> (target: TerminalCommentThreads.Target?, refusal: String?) {
        let services = ctx.services
        guard services.settings?.snapshot.commentThreads == true else { return (nil, TerminalToChatPlaceholders.reason) }
        guard let (tab, pane) = ctx.daemonTab(invocation), tab.kind == .pty || tab.kind == .remoteTerminal else { return (nil, RefusalStrings.notATerminal) }
        guard let chat = services.workspaceAgentChat(near: pane), let session = chat.tab.agentSession?.session, !session.isEmpty else {
            return (nil, TerminalCommentStrings.noChat)
        }
        guard let link = services.viewers.diffPages.gitLink(for: chat.tab), link.supportsDiffCommentThreads else { return (nil, TerminalToChatPlaceholders.reason) }
        guard let root = NewTerminalStart.folder(of: chat.tab, services: services) ?? tab.cwd, root.hasPrefix("/") else {
            return (nil, TerminalCommentStrings.noChat)
        }
        let terminal = CommentedTerminal(id: tab.id, title: tab.displayTitle, cwd: tab.cwd)
        return (TerminalCommentThreads.Target(terminal: terminal, acpSession: session, link: link, root: root), nil)
    }
}
