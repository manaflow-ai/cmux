import CmuxCommandPalette
import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return CommandPaletteViewContributionProvider().build(
            strings: CommandPaletteViewContributionProvider.Strings(
                triggerFlashTitle: String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel"),
                triggerFlashSubtitle: String(localized: "command.triggerFlash.subtitle", defaultValue: "View"),
                openTaskManagerTitle: String(localized: "taskManager.title", defaultValue: "Task Manager"),
                openTaskManagerSubtitle: String(localized: "command.closeWindow.subtitle", defaultValue: "Window")
            )
        ) + [
            CommandPaletteCommandContribution(
                commandId: "palette.sleepyMode",
                title: constant(String(localized: "command.sleepyMode.title", defaultValue: "Sleepy Mode")),
                subtitle: constant(String(localized: "command.sleepyMode.subtitle", defaultValue: "View")),
                keywords: ["sleepy", "screensaver", "caffeinate", "keep awake", "do not sleep", "lock", "night"]
            )
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: "palette.sleepyMode") {
            SleepyModeController.shared.activate()
        }
    }
}
