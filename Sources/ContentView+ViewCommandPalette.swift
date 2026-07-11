import CmuxCommandPalette
import Foundation

extension ContentView {
    func commandPaletteSurfaceKindLabel(for panelType: PanelType) -> String {
        switch panelType {
        case .terminal:
            return String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "commandPalette.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "commandPalette.kind.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "commandPalette.kind.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            return String(localized: "commandPalette.kind.rightSidebarTool", defaultValue: "Tool")
        case .customSidebar:
            return String(localized: "commandPalette.kind.customSidebar", defaultValue: "Custom Sidebar")
        case .agentSession:
            return String(localized: "commandPalette.kind.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "commandPalette.kind.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .cloudVMLoading:
            return String(localized: "commandPalette.kind.cloudVMLoading", defaultValue: "Cloud VM")
        case .androidEmulator:
            return String(localized: "commandPalette.kind.androidEmulator", defaultValue: "Android Emulator")
        }
    }

    func commandPaletteSurfaceKeywords(for panelType: PanelType) -> [String] {
        switch panelType {
        case .terminal:
            return ["terminal", "shell", "console"]
        case .browser:
            return ["browser", "web", "page"]
        case .markdown:
            return ["markdown", "note", "preview"]
        case .filePreview:
            return ["file", "preview", "text", "pdf", "image", "audio", "video"]
        case .rightSidebarTool:
            return ["tool", "files", "find", "vault", "sidebar"]
        case .customSidebar:
            return ["custom", "sidebar", "pane"]
        case .agentSession:
            return ["agent", "codex", "claude", "opencode", "react", "solid"]
        case .project:
            return ["project", "xcode", "build", "settings", "schemes", "targets"]
        case .extensionBrowser:
            return ["sidebar", "extensions", "extensionkit", "browser"]
        case .cloudVMLoading:
            return ["cloud", "vm", "loading"]
        case .androidEmulator:
            return ["android", "emulator", "device", "mobile"]
        }
    }

    static func commandPaletteAndroidEmulatorContribution() -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.androidEmulators",
            title: { _ in String(
                localized: "command.androidEmulators.title",
                defaultValue: "Open Android Emulators…"
            ) },
            subtitle: { _ in String(
                localized: "command.androidEmulators.subtitle",
                defaultValue: "Developer Tools"
            ) },
            keywords: ["android", "emulator", "avd", "device", "studio", "sdk"]
        )
    }

    func registerAndroidEmulatorCommandHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.androidEmulators") {
            AppDelegate.shared?.showAndroidEmulators()
        }
    }

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
