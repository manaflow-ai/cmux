import AppKit
import Bonsplit
import CmuxCommandPalette
import CmuxFoundation
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
                commandId: "palette.swapWithSession",
                title: constant(CmuxPaneSwapStrings().swapWithSession),
                subtitle: constant(CmuxPaneSwapStrings().terminalPane),
                keywords: ["swap", "pane", "session", "terminal", "exchange"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.panelHasPane)
                }
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
        registry.register(commandId: "palette.swapWithSession") {
            if !PaneSwapSelectionController().beginFocused(in: tabManager) {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: "palette.sleepyMode") {
            SleepyModeController.shared.activate()
        }
    }
}

/// Command palette entries for shortcut actions that had no palette or menu
/// entry. Each title is the shortcut's own localized label, and each handler
/// runs the same shared AppDelegate path as the keyboard shortcut.
enum ShortcutParityPaletteCommand: String, CaseIterable {
    case toggleTerminalCopyMode = "palette.toggleTerminalCopyMode"
    case increaseWorkspaceTerminalFontSize = "palette.increaseWorkspaceTerminalFontSize"
    case decreaseWorkspaceTerminalFontSize = "palette.decreaseWorkspaceTerminalFontSize"
    case resetWorkspaceTerminalFontSize = "palette.resetWorkspaceTerminalFontSize"
    case focusPaneLeft = "palette.focusPaneLeft"
    case focusPaneRight = "palette.focusPaneRight"
    case focusPaneUp = "palette.focusPaneUp"
    case focusPaneDown = "palette.focusPaneDown"
    case focusPreviousPane = "palette.focusPreviousPane"
    case focusNextPane = "palette.focusNextPane"
    case groupSelectedWorkspaces = "palette.groupSelectedWorkspaces"
    case toggleFocusedWorkspaceGroupCollapsed = "palette.toggleFocusedWorkspaceGroupCollapsed"
    case browserHardReload = "palette.browserHardReload"

    enum Scope {
        case terminal
        case workspace
        case splits
        case browser
    }

    var shortcutAction: KeyboardShortcutSettings.Action {
        switch self {
        case .toggleTerminalCopyMode: return .toggleTerminalCopyMode
        case .increaseWorkspaceTerminalFontSize: return .increaseWorkspaceTerminalFontSize
        case .decreaseWorkspaceTerminalFontSize: return .decreaseWorkspaceTerminalFontSize
        case .resetWorkspaceTerminalFontSize: return .resetWorkspaceTerminalFontSize
        case .focusPaneLeft: return .focusLeft
        case .focusPaneRight: return .focusRight
        case .focusPaneUp: return .focusUp
        case .focusPaneDown: return .focusDown
        case .focusPreviousPane: return .focusPreviousPane
        case .focusNextPane: return .focusNextPane
        case .groupSelectedWorkspaces: return .groupSelectedWorkspaces
        case .toggleFocusedWorkspaceGroupCollapsed: return .toggleFocusedWorkspaceGroupCollapsed
        case .browserHardReload: return .browserHardReload
        }
    }

    /// The pane focus move for the focus commands, or nil for the others.
    var paneFocusRoute: GhosttyGotoSplitRoute? {
        switch self {
        case .focusPaneLeft: return .direction(.left)
        case .focusPaneRight: return .direction(.right)
        case .focusPaneUp: return .direction(.up)
        case .focusPaneDown: return .direction(.down)
        case .focusPreviousPane: return .previous
        case .focusNextPane: return .next
        default: return nil
        }
    }

    var scope: Scope {
        switch self {
        case .toggleTerminalCopyMode:
            return .terminal
        case .increaseWorkspaceTerminalFontSize, .decreaseWorkspaceTerminalFontSize,
             .resetWorkspaceTerminalFontSize, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed:
            return .workspace
        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .focusPreviousPane, .focusNextPane:
            return .splits
        case .browserHardReload:
            return .browser
        }
    }

    var keywords: [String] {
        switch self {
        case .toggleTerminalCopyMode:
            return ["terminal", "copy", "mode", "select", "vi", "keyboard", "scrollback"]
        case .increaseWorkspaceTerminalFontSize:
            return ["terminal", "font", "size", "zoom", "bigger", "increase", "workspace"]
        case .decreaseWorkspaceTerminalFontSize:
            return ["terminal", "font", "size", "zoom", "smaller", "decrease", "workspace"]
        case .resetWorkspaceTerminalFontSize:
            return ["terminal", "font", "size", "zoom", "reset", "default", "workspace"]
        case .focusPaneLeft:
            return ["pane", "split", "focus", "move", "navigate", "left"]
        case .focusPaneRight:
            return ["pane", "split", "focus", "move", "navigate", "right"]
        case .focusPaneUp:
            return ["pane", "split", "focus", "move", "navigate", "up"]
        case .focusPaneDown:
            return ["pane", "split", "focus", "move", "navigate", "down"]
        case .focusPreviousPane:
            return ["pane", "split", "focus", "cycle", "previous"]
        case .focusNextPane:
            return ["pane", "split", "focus", "cycle", "next"]
        case .groupSelectedWorkspaces:
            return ["workspace", "group", "selected", "folder", "combine"]
        case .toggleFocusedWorkspaceGroupCollapsed:
            return ["workspace", "group", "collapse", "expand", "fold"]
        case .browserHardReload:
            return ["browser", "reload", "refresh", "hard", "cache"]
        }
    }
}

extension ContentView {
    /// Palette context key: the terminal a terminal shortcut would act on is
    /// focused. That is the focused Dock panel while the Dock owns keyboard
    /// focus, else the main-area focused panel.
    static let commandPaletteShortcutTerminalFocusedKey = CommandPaletteContextKeys(
        rawValue: "shortcut.terminalFocused"
    )

    static func commandPaletteShortcutTerminalFocused(
        focusedDockPanelIsTerminal: Bool?,
        mainAreaPanelIsTerminal: Bool
    ) -> Bool {
        focusedDockPanelIsTerminal ?? mainAreaPanelIsTerminal
    }

    /// Whether a command's post-run focus restore targets the focused Dock
    /// panel while the Dock owns keyboard focus, because the command itself
    /// acts on the Dock first like its shortcut.
    static func commandPalettePostRunFocusFollowsFocusedDock(forCommandId commandId: String) -> Bool {
        commandId == ShortcutParityPaletteCommand.toggleTerminalCopyMode.rawValue
    }

    static func commandPaletteShortcutParityContributions(
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        terminalSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        browserSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        ShortcutParityPaletteCommand.allCases.map { command in
            let action = command.shortcutAction
            let subtitle: (CommandPaletteContextSnapshot) -> String
            let when: (CommandPaletteContextSnapshot) -> Bool
            switch command.scope {
            case .terminal:
                subtitle = terminalSubtitle
                when = { $0.bool(Self.commandPaletteShortcutTerminalFocusedKey) }
            case .workspace:
                subtitle = workspaceSubtitle
                when = { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            case .splits:
                subtitle = workspaceSubtitle
                when = { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            case .browser:
                subtitle = browserSubtitle
                when = { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            }
            return CommandPaletteCommandContribution(
                commandId: command.rawValue,
                title: { _ in action.label },
                subtitle: subtitle,
                keywords: command.keywords,
                when: when
            )
        }
    }

    func registerShortcutParityCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        performBrowserAction: @escaping (BrowserAction) -> Bool,
        preferredWindow: @escaping () -> NSWindow?
    ) {
        for command in ShortcutParityPaletteCommand.allCases {
            registry.register(commandId: command.rawValue) {
                if !Self.performShortcutParityCommand(
                    command,
                    performBrowserAction: performBrowserAction,
                    preferredWindow: preferredWindow()
                ) {
                    NSSound.beep()
                }
            }
        }
    }

    /// Runs one shortcut-parity command through the keyboard shortcut's
    /// shared path. Returns false when nothing was handled.
    static func performShortcutParityCommand(
        _ command: ShortcutParityPaletteCommand,
        performBrowserAction: (BrowserAction) -> Bool,
        preferredWindow: NSWindow?
    ) -> Bool {
        if let route = command.paneFocusRoute {
            return AppDelegate.shared?.performPaneFocusShortcut(
                route,
                preferredWindow: preferredWindow
            ) ?? false
        }
        switch command {
        case .toggleTerminalCopyMode:
            return AppDelegate.shared?.performToggleTerminalCopyModeShortcut(
                preferredWindow: preferredWindow
            ) ?? false
        case .increaseWorkspaceTerminalFontSize, .decreaseWorkspaceTerminalFontSize,
             .resetWorkspaceTerminalFontSize:
            return AppDelegate.shared?.performWorkspaceTerminalFontSizeAction(
                command.shortcutAction,
                preferredWindow: preferredWindow
            ) ?? false
        case .groupSelectedWorkspaces:
            return AppDelegate.shared?.handleGroupSelectedWorkspacesShortcut(
                preferredWindow: preferredWindow
            ) ?? false
        case .toggleFocusedWorkspaceGroupCollapsed:
            return AppDelegate.shared?.handleToggleFocusedWorkspaceGroupCollapsedShortcut(
                preferredWindow: preferredWindow
            ) ?? false
        case .browserHardReload:
            return performBrowserAction(.hardReload)
        case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .focusPreviousPane, .focusNextPane:
            return false
        }
    }
}
