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
        bindUnported(registry)
    }

    /// Runs a Ghostty binding action on the targeted or focused terminal.
    static func perform(_ binding: String, _ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let entry = ctx.terminal(invocation) else { return }
        if !entry.session.surfaceView.performBindingAction(binding) { ctx.refuse("Ghostty rejected \(binding)") }
    }

    static func selection(of entry: TerminalEntry) -> String? {
        entry.session.surfaceView.accessibilitySelectedText().flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func bindClipboard(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        registry.bind("terminalCopy", invoke: { invocation in
            guard let entry = ctx.terminal(invocation) else { return }
            guard selection(of: entry) != nil else { return ctx.refuse("nothing is selected") }
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
            guard case .terminal = content, let key = pane.currentTabKey else { return ctx.refuse("the tab is not a terminal") }
            ctx.services.cache.release(key)
            pane.showSelected()
            pane.focusContent()
        })
    }

    private static func bindUnported(_ registry: ActionRegistry) {
        registry.bindUnavailable("toggleTerminalCopyMode", reason: "needs a keyboard copy mode in the cmux-next terminal")
        let textBox = "needs the TextBox composer, which cmux-next does not have yet"
        for id: ActionID in ["focusTextBoxInput", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction", "attachTextBoxFile"] {
            registry.bindUnavailable(id, reason: textBox)
        }
        for id: ActionID in ["resumeCommandSet", "resumeCommandEdit", "resumeCommandClear"] {
            registry.bindUnavailable(id, reason: "needs daemon capability resume-command")
        }
        registry.bindUnavailable("findInDirectory", reason: "needs the Find panel (not in cmux-next yet)")
    }
}
