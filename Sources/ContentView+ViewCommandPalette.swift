import CmuxCommandPalette
import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        CommandPaletteViewContributionProvider().build(
            strings: CommandPaletteViewContributionProvider.Strings(
                triggerFlashTitle: String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel"),
                triggerFlashSubtitle: String(localized: "command.triggerFlash.subtitle", defaultValue: "View"),
                openTaskManagerTitle: String(localized: "taskManager.title", defaultValue: "Task Manager"),
                openTaskManagerSubtitle: String(localized: "command.closeWindow.subtitle", defaultValue: "Window")
            )
        )
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
    }
}
