import AppKit
import Foundation

enum AgentHibernationEnableWarning {
#if DEBUG
    static var confirmationHandlerForTests: (() -> Bool)?
#endif

    static var title: String {
        String(
            localized: "settings.terminal.agentHibernation.hooksWarning.title",
            defaultValue: "Enable Agent Hibernation without hooks?"
        )
    }

    static var message: String {
        String(
            localized: "settings.terminal.agentHibernation.hooksWarning.message",
            defaultValue: "Agent Hibernation relies on agent lifecycle hooks to know when sessions are idle. Enable or set up an agent integration first, or run `cmux hooks setup`, before relying on hibernation."
        )
    }

    static var enableAnywayTitle: String {
        String(
            localized: "settings.terminal.agentHibernation.hooksWarning.enableAnyway",
            defaultValue: "Enable Anyway"
        )
    }

    static func confirmEnableWithoutHooks() -> Bool {
#if DEBUG
        if let confirmationHandlerForTests {
            return confirmationHandlerForTests()
        }
#endif
        guard Thread.isMainThread else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: enableAnywayTitle)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
