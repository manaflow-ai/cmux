import CmuxCommandPalette
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
                keywords: ["flash", "highlight", "focus", "panel"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.sleepyMode",
                title: constant(String(localized: "command.sleepyMode.title", defaultValue: "Sleepy Mode")),
                subtitle: constant(String(localized: "command.sleepyMode.subtitle", defaultValue: "View")),
                keywords: ["sleepy", "screensaver", "caffeinate", "keep awake", "do not sleep", "lock", "pets", "night"]
            ),
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

    func registerViewCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext,
        showTaskManager: @escaping @MainActor () -> Void = {
            TaskManagerWindowController.shared.show()
        },
        activateSleepyMode: @escaping @MainActor () -> Void = {
            SleepyModeController.shared.activate()
        }
    ) {
        registry.register(commandId: "palette.triggerFlash") { _ in
            guard context.target.windowID == windowId,
                  context.owningWindowID == windowId,
                  let (workspace, panelID, _) = context.panel() else {
                return .targetUnavailable
            }
            workspace.triggerFocusFlash(panelId: panelID)
            return .completed
        }
        registry.register(commandId: "palette.openTaskManager") { _ in
            guard commandPaletteViewPresentationTargetIsAvailable(context) else {
                return .targetUnavailable
            }
            showTaskManager()
            return .presented
        }
        registry.register(commandId: "palette.sleepyMode") { _ in
            guard commandPaletteViewPresentationTargetIsAvailable(context) else {
                return .targetUnavailable
            }
            activateSleepyMode()
            return .presented
        }
    }

    private func commandPaletteViewPresentationTargetIsAvailable(
        _ context: CommandPaletteActionContext
    ) -> Bool {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let appDelegate = AppDelegate.shared,
              let liveContext = appDelegate.liveMainWindowContextForAction(
                  tabManager: context.tabManager
              ),
              liveContext.windowId == context.target.windowID else {
            return false
        }
        if context.target.panelID != nil {
            return context.panel() != nil
        }
        if context.target.workspaceID != nil {
            return context.workspace() != nil
        }
        return true
    }
}
