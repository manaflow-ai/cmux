import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings

/// Runs a cmux.json command action: types its command, then Return, into a
/// new terminal tab in the targeted pane, or into the targeted pane's
/// selected terminal.
enum ConfigCommandRunner {
    static func run(_ action: ConfigCommandAction, invocation: ActionInvocation, context: AppActionContext) {
        let text = action.command + "\r"
        switch action.target {
        case .newTabInCurrentPane:
            context.paneController(invocation)?.newTerminalTab(typing: text)
        case .currentTerminal:
            guard let (tab, _) = context.daemonTab(invocation) else { return }
            guard tab.kind == .pty else { return context.refuse(RefusalStrings.notATerminal) }
            let surface = tab.surface
            context.send("config-action") { try await $0.send(surface, text: text) }
        }
    }
}
