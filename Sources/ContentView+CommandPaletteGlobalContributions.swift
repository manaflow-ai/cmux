import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Command Palette Global Command Contributions
extension ContentView {
    func appendCommandPaletteGlobalContributions(to contributions: inout [CommandPaletteCommandContribution]) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'cmux' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'cmux' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolderInVSCodeInline",
                title: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.title",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ),
                subtitle: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.subtitle",
                        defaultValue: "VS Code Inline"
                    )
                ),
                keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
                when: { _ in TerminalDirectoryOpenTarget.vscodeInline.isAvailable() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenPreviousSession",
                title: constant(String(localized: "command.reopenPreviousSession.title", defaultValue: "Restore Previous App Launch")),
                subtitle: constant(String(localized: "command.reopenPreviousSession.subtitle", defaultValue: "History")),
                keywords: ["reopen", "restore", "previous", "session", "launch", "resume"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)")),
                subtitle: constant(String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Tab")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed")),
                subtitle: constant(String(localized: "menu.history.title", defaultValue: "History")),
                keywords: ["reopen", "closed", "recently", "history", "tab", "workspace", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleLeftSidebar.title", defaultValue: "Toggle Left Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "left", "layout"]
            )
        )
        // "Sidebar: <provider>" switch commands for each available view. The
        // built-in views are always offered; `descriptors` adds the hosted
        // extension sidebar only while the experimental Extensions beta is on.
        for descriptor in CmuxExtensionSidebarSelection.descriptors {
            let title = CmuxExtensionSidebarSelection.localizedTitle(for: descriptor)
            let titleFormat = String(localized: "command.switchExtensionSidebar.title", defaultValue: "Sidebar: %@")
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandPaletteExtensionSidebarCommandID(descriptor.id),
                    title: constant(String.localizedStringWithFormat(titleFormat, title)),
                    subtitle: constant(String(localized: "command.switchExtensionSidebar.subtitle", defaultValue: "Choose Sidebar")),
                    keywords: ["sidebar", "switch", "extension", title.lowercased()]
                )
            )
        }
        contributions.append(contentsOf: Self.commandPaletteRightSidebarModeCommandContributions())
        contributions.append(contentsOf: Self.commandPaletteRightSidebarToolPaneCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleMatchTerminalBackground",
                title: { context in
                    context.bool(CommandPaletteContextKeys.sidebarMatchTerminalBackground)
                        ? String(localized: "command.disableMatchTerminalBackground.title", defaultValue: "Disable Match Terminal Background")
                        : String(localized: "command.enableMatchTerminalBackground.title", defaultValue: "Enable Match Terminal Background")
                },
                subtitle: constant(String(localized: "command.matchTerminalBackground.subtitle", defaultValue: "Sidebar")),
                keywords: ["match", "terminal", "background", "transparency", "sidebar", "surface", "chrome"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(contentsOf: Self.commandPaletteViewCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleUnread",
                title: constant(String(localized: "command.toggleUnread.title", defaultValue: "Toggle Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["toggle", "mark", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markOldestUnreadAndJumpNext",
                title: constant(
                    String(
                        localized: "command.markOldestUnreadAndJumpNext.title",
                        defaultValue: "Mark as Oldest Unread and Jump to Next Latest Unread"
                    )
                ),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["mark", "oldest", "unread", "jump", "next", "notification", "defer"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openCmuxSettingsFile",
                title: constant(String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json")),
                subtitle: constant(String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")),
                keywords: ["open", "cmux", "json", "config", "configuration", "settings", "file", "editor", "dotfile"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openGhosttySettings",
                title: constant(
                    String(
                        localized: "command.openGhosttySettings.title",
                        defaultValue: "Open Ghostty Settings in TextEdit"
                    )
                ),
                subtitle: constant(
                    String(localized: "command.openGhosttySettings.subtitle", defaultValue: "Ghostty Config Files")
                ),
                keywords: ["open", "ghostty", "settings", "config", "configuration", "file", "textedit", "terminal"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.mobileConnect",
                title: constant(String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")),
                subtitle: constant(String(localized: "command.mobileConnect.subtitle", defaultValue: "Mobile")),
                keywords: Self.commandPaletteMobileConnectKeywords
            )
        )
        contributions.append(contentsOf: Self.commandPaletteAuthCommandContributions())
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.makeDefaultTerminal",
                title: constant(
                    String(
                        localized: "command.makeDefaultTerminal.title",
                        defaultValue: "Make cmux the Default Terminal"
                    )
                ),
                subtitle: constant(
                    String(localized: "command.makeDefaultTerminal.subtitle", defaultValue: "Global")
                ),
                keywords: String(
                    localized: "command.makeDefaultTerminal.keywords",
                    defaultValue: "default,terminal,ssh,launch,services,handler,command,tool,executable"
                )
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
                when: { !$0.bool(CommandPaletteContextKeys.defaultTerminalIsDefault) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableBrowser",
                title: constant(String(localized: "command.disableBrowser.title", defaultValue: "Disable cmux Browser")),
                subtitle: constant(String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "disable", "external", "default", "open", "auth"],
                when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableBrowser",
                title: constant(String(localized: "command.enableBrowser.title", defaultValue: "Enable cmux Browser")),
                subtitle: constant(String(localized: "command.browserAvailability.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "enable", "embedded", "open"],
                when: { $0.bool(CommandPaletteContextKeys.browserDisabled) }
            )
        )
        contributions.append(contentsOf: Self.commandPaletteSettingsToggleCommandContributions())
    }
}
