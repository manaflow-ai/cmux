import AppKit
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
                keywords: ["flash", "highlight", "focus", "panel"]
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
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalFloatingWindow",
                title: constant(String(
                    localized: "command.newTerminalFloatingWindow.title",
                    defaultValue: "New Terminal Floating Window"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["terminal", "floating", "dock", "workspace", "window", "shell"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.newNotesFloatingWindow",
                title: constant(String(
                    localized: "command.newNotesFloatingWindow.title",
                    defaultValue: "New Notes Floating Window"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["notes", "floating", "dock", "workspace", "window", "scratchpad"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserFloatingWindow",
                title: constant(String(
                    localized: "command.newBrowserFloatingWindow.title",
                    defaultValue: "New Browser Floating Window"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["browser", "web", "floating", "dock", "workspace", "window"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.stashFloatingWindow",
                title: constant(String(
                    localized: "command.stashFloatingWindow.title",
                    defaultValue: "Stash Floating Window"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["stash", "minimize", "hide", "floating", "dock", "window"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.restoreStashedFloatingWindows",
                title: constant(String(
                    localized: "command.restoreStashedFloatingWindows.title",
                    defaultValue: "Restore Stashed Floating Windows"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["restore", "stash", "show", "floating", "dock", "windows"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.customizeFloatingWindowColor",
                title: constant(String(
                    localized: "command.customizeFloatingWindowColor.title",
                    defaultValue: "Customize Floating Window Color…"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["color", "tint", "glass", "floating", "dock", "window"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.resetFloatingWindowColor",
                title: constant(String(
                    localized: "command.resetFloatingWindowColor.title",
                    defaultValue: "Reset Floating Window Color"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["reset", "default", "color", "tint", "floating", "window"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.closeAllWorkspaceFloatingWindows",
                title: constant(String(
                    localized: "command.closeAllWorkspaceFloatingWindows.title",
                    defaultValue: "Close All Floating Windows in Workspace"
                )),
                subtitle: constant(String(localized: "command.workspace.subtitle", defaultValue: "Workspace")),
                keywords: ["close", "all", "floating", "dock", "workspace", "windows"]
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
        registry.register(commandId: "palette.newTerminalFloatingWindow") {
            createWorkspaceFloatingDockFromCommandPalette(initialContent: .terminal)
        }
        registry.register(commandId: "palette.newNotesFloatingWindow") {
            createWorkspaceFloatingDockFromCommandPalette(initialContent: .note)
        }
        registry.register(commandId: "palette.newBrowserFloatingWindow") {
            createWorkspaceFloatingDockFromCommandPalette(initialContent: .browser)
        }
        registry.register(commandId: "palette.stashFloatingWindow") {
            if AppDelegate.shared?.stashPreferredWorkspaceFloatingDock(in: tabManager) != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.restoreStashedFloatingWindows") {
            if AppDelegate.shared?.restoreAllStashedWorkspaceFloatingDocks(
                in: tabManager,
                focus: true
            ) == nil {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.customizeFloatingWindowColor") {
            if AppDelegate.shared?.customizeWorkspaceFloatingDockColor(in: tabManager) != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.resetFloatingWindowColor") {
            if AppDelegate.shared?.resetWorkspaceFloatingDockColor(in: tabManager) != true {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.closeAllWorkspaceFloatingWindows") {
            if AppDelegate.shared?.closeAllWorkspaceFloatingDocks(in: tabManager) == nil {
                NSSound.beep()
            }
        }
    }

    private func createWorkspaceFloatingDockFromCommandPalette(initialContent: DockSurfaceKind) {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        _ = AppDelegate.shared?.createWorkspaceFloatingDock(
            in: workspace,
            tabManager: tabManager,
            request: WorkspaceFloatingDockCreationRequest(
                initialContent: initialContent,
                focus: true
            )
        )
    }
}
