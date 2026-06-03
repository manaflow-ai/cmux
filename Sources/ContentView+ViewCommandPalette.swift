import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openHistoryPane",
                title: constant(String(localized: "command.openHistoryPane.title", defaultValue: "Open Session History")),
                subtitle: constant(String(localized: "command.openRightSidebarToolAsPane.subtitle", defaultValue: "Pane")),
                keywords: ["history", "session", "sessions", "vault", "agent", "claude", "codex", "resume", "transcript", "pane"]
            ),
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: "palette.openHistoryPane") {
            openHistoryPane()
        }
    }
}
