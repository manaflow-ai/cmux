import CmuxCommandPalette
import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        var contributions: [CommandPaletteCommandContribution] = [
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
        // DEBUG-only, like the Debug menu entry: the CEF runtime is
        // bundled only into Debug builds (scripts/copy-cef-runtime-dev.sh),
        // so Release builds must not advertise a command that can never
        // open a browser.
        #if DEBUG
        contributions.append(CommandPaletteCommandContribution(
            commandId: "palette.openCefBrowser",
            title: constant(String(localized: "command.openCefBrowser.title", defaultValue: "Chromium Browser (CEF)")),
            subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
            keywords: ["chromium", "cef", "chrome", "browser", "devtools", "extension", "profile"]
        ))
        contributions.append(CommandPaletteCommandContribution(
            commandId: "palette.cefBrowserSplitRight",
            title: constant(String(
                localized: "command.cefBrowserSplitRight.title",
                defaultValue: "Chromium Browser: Split Right"
            )),
            subtitle: constant(String(
                localized: "command.openRightSidebarToolAsPane.subtitle",
                defaultValue: "Pane"
            )),
            keywords: ["chromium", "cef", "chrome", "browser", "pane", "split", "right"],
            when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
        ))
        #endif
        return contributions
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
        #if DEBUG
        registry.register(commandId: "palette.openCefBrowser") {
            CEFBrowserDebugWindowController.shared.show()
        }
        registry.register(commandId: "palette.cefBrowserSplitRight") {
            guard let workspace = tabManager.selectedWorkspace,
                  let focusedPanelId = workspace.focusedPanelId else { return }
            _ = workspace.newCEFBrowserSplit(from: focusedPanelId)
        }
        #endif
    }
}
