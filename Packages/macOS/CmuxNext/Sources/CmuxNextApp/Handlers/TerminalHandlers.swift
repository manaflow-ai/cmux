import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal

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
        bindCopyMode(registry, ctx)
        bindUnported(registry)
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
            guard selection(of: entry) != nil else { return ctx.refuse(RefusalStrings.nothingSelected) }
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
        let bindings: [(ActionID, String)] = [
            ("resetTerminal", "reset"),
            ("terminal.increaseFontSize", "increase_font_size:1"),
            ("terminal.decreaseFontSize", "decrease_font_size:1"),
            ("terminal.resetFontSize", "reset_font_size"),
            ("terminal.scrollPageUp", "scroll_page_up"),
            ("terminal.scrollPageDown", "scroll_page_down"),
            ("terminal.scrollToTop", "scroll_to_top"),
            ("terminal.scrollToBottom", "scroll_to_bottom"),
            ("terminal.scrollToSelection", "scroll_to_selection"),
        ]
        for (id, binding) in bindings {
            registry.bind(id, invoke: { perform(binding, $0, ctx) })
        }
        // Cmd-K (decision K1): the daemon owns the terminal state, so the clear happens there and
        // reaches every view; Ghostty's clear_screen on the app's mirror alone is undone by the
        // next frame and comes back on reattach.
        registry.bind("terminal.clear", invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            if tab.kind == .remoteTerminal { return clearRemoteTerminal(tab, ctx) }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            let surface = tab.surface
            clear(on: ctx.services.activeDaemon, ctx) { _ = try await $0.request(ClearHistoryRequest(surface: surface)) }
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
                              _ body: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        guard daemon.connection != nil else { return ctx.refuse(MiscHandlerStrings.daemonOffline) }
        let reporter = ctx.services.crashReporting.reporter
        daemon.send("clear-history", onFailure: { failure in
            reporter.recordFailure("terminal.clear", message: Self.failureKind(failure.message))
        }, body)
    }

    /// The daemon's refusal reason without user content (no paths or screen text).
    static func failureKind(_ message: String) -> String {
        let known = ["active terminal input extends into retained history", "safe clear-history boundary",
                     "does not support clear-history", "terminal host has exited", "terminal process has exited",
                     "did not acknowledge ClearHistory", "not connected", "timed out"]
        return known.first { message.contains($0) } ?? "other"
    }

    /// `terminal keep [--on false]`: the tab's terminal outlives its last
    /// tab (`terminal-reap-v1`); off lets the daemon end it after the reap
    /// grace period once no tab shows it.
    private static func bindKeep(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("terminal.keep", unavailable: ctx.needs(DaemonCapabilities.shared.terminalReap), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            let keep = invocation["on"]?.boolValue ?? true, surface = tab.surface
            ctx.send("set-terminal-keep") { _ = try await $0.setTerminalKeep(.surface(surface), keep: keep) }
        })
    }

    /// Vim-style keyboard copy mode over the scrollback (⇧⌘M); the terminal
    /// view takes the keys until Esc, q, or a copy.
    private static func bindCopyMode(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("toggleTerminalCopyMode", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            if !entry.session.surfaceView.toggleCopyMode() { ctx.refuse(RefusalStrings.ghosttyRejected("keyboard_copy_cursor_set")) }
        })
    }

    private static func bindUnported(_ registry: ActionRegistry) {
        let textBox = RefusalStrings.textBoxUnported
        for id: ActionID in ["focusTextBoxInput", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction", "attachTextBoxFile"] {
            registry.bindUnavailable(id, reason: textBox)
        }
        for id: ActionID in ["resumeCommandSet", "resumeCommandEdit", "resumeCommandClear"] {
            registry.bindUnavailable(id, reason: RefusalStrings.needsDaemonCapability("resume-command"))
        }
    }
}
