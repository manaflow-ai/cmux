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
        bindUnported(registry)
    }

    /// Runs a Ghostty binding action on the targeted or focused terminal.
    static func perform(_ binding: String, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let entry = ctx.terminal(invocation) else { return }
        if !entry.session.surfaceView.performBindingAction(binding) { ctx.refuse(RefusalStrings.ghosttyRejected(String(describing: binding))) }
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
            ("terminal.clear", "clear_screen"),
            ("resetTerminal", "reset"),
            ("terminal.increaseFontSize", "increase_font_size:1"),
            ("terminal.decreaseFontSize", "decrease_font_size:1"),
            ("terminal.resetFontSize", "reset_font_size"),
            ("terminal.scrollPageUp", "scroll_page_up"),
            ("terminal.scrollPageDown", "scroll_page_down"),
            ("terminal.scrollToTop", "scroll_to_top"),
            ("terminal.scrollToBottom", "scroll_to_bottom"),
        ]
        for (id, binding) in bindings {
            registry.bind(id, invoke: { perform(binding, $0, ctx) })
        }
        registry.bind("reconnectPane", invoke: { invocation in
            guard let (pane, content) = ctx.visibleContent(invocation) else { return }
            guard case .terminal = content, let key = pane.currentTabKey else { return ctx.refuse(RefusalStrings.notATerminal) }
            ctx.services.cache.release(key)
            pane.showSelected()
            pane.focusContent()
        })
    }

    /// `terminal keep [--on false]`: the tab's terminal outlives its last
    /// tab (`terminal-reap-v1`); off lets the daemon end it after the reap
    /// grace period once no tab shows it.
    private static func bindKeep(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("terminal.keep", unavailable: ctx.needs(DaemonCapabilities.terminalReap), invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return ctx.refuse(RefusalStrings.notATerminal) }
            let keep = invocation["on"]?.boolValue ?? true, surface = tab.surface
            ctx.send("set-terminal-keep") { _ = try await $0.setTerminalKeep(.surface(surface), keep: keep) }
        })
    }

    private static func bindUnported(_ registry: ActionRegistry) {
        registry.bindUnavailable("toggleTerminalCopyMode", reason: RefusalStrings.copyModeUnported)
        let textBox = RefusalStrings.textBoxUnported
        for id: ActionID in ["focusTextBoxInput", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction", "attachTextBoxFile"] {
            registry.bindUnavailable(id, reason: textBox)
        }
        for id: ActionID in ["resumeCommandSet", "resumeCommandEdit", "resumeCommandClear"] {
            registry.bindUnavailable(id, reason: RefusalStrings.needsDaemonCapability("resume-command"))
        }
        registry.bindUnavailable("findInDirectory", reason: RefusalStrings.findPanelUnported)
    }
}
