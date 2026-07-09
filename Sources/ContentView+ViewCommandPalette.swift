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

    static func appendViewZoomCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func browserOrTextPreview(_ context: CommandPaletteContextSnapshot) -> Bool {
            context.bool(CommandPaletteContextKeys.panelIsBrowser)
                || context.bool(CommandPaletteContextKeys.panelIsFilePreviewTextEditor)
        }

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In")),
                subtitle: panelSubtitle,
                keywords: ["browser", "file", "text", "preview", "zoom", "font", "in"],
                when: browserOrTextPreview
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: panelSubtitle,
                keywords: ["browser", "file", "text", "preview", "zoom", "font", "out"],
                when: browserOrTextPreview
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size")),
                subtitle: panelSubtitle,
                keywords: ["browser", "file", "text", "preview", "zoom", "font", "reset", "actual size"],
                when: browserOrTextPreview
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
        registry.register(commandId: "palette.sleepyMode") {
            SleepyModeController.shared.activate()
        }
    }
}
