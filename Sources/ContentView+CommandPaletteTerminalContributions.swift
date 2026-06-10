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


// MARK: - Command Palette Terminal Command Contributions
extension ContentView {
    func appendCommandPaletteTerminalContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        terminalPanelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.findInDirectory",
                title: constant(String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…")),
                subtitle: constant(String(localized: "command.findInDirectory.subtitle", defaultValue: "Right Sidebar")),
                keywords: ["files", "directory", "find", "search"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalToggleTextBoxInput",
                title: constant(String(localized: "command.terminalToggleTextBoxInput.title", defaultValue: "Toggle TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFocusTextBoxInput",
                title: constant(String(localized: "command.terminalFocusTextBoxInput.title", defaultValue: "Focus TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "prompt", "focus"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalAttachTextBoxFile",
                title: constant(String(localized: "command.terminalAttachTextBoxFile.title", defaultValue: "Attach File to TextBox Input")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "textbox", "text", "box", "rich", "input", "attach", "file", "image"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSendCtrlF",
                title: constant(String(localized: "command.terminalSendCtrlF.title", defaultValue: "Send Ctrl-F to Terminal")),
                subtitle: terminalPanelSubtitle,
                keywords: [
                    "terminal", "ctrl", "control", "f", "send", "key", "passthrough",
                    "force", "stop", "agent", "agents", "claude", "code", "hung", "background", "watchdog", "kill",
                ],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationRight",
                title: constant(String(localized: "command.forkAgentConversationRight.title", defaultValue: "Fork Conversation to the Right")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "right", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationLeft",
                title: constant(String(localized: "command.forkAgentConversationLeft.title", defaultValue: "Fork Conversation to the Left")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "left", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationTop",
                title: constant(String(localized: "command.forkAgentConversationTop.title", defaultValue: "Fork Conversation to the Top")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "top", "up", "above", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationBottom",
                title: constant(String(localized: "command.forkAgentConversationBottom.title", defaultValue: "Fork Conversation to the Bottom")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "bottom", "down", "below", "split"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewTab",
                title: constant(String(localized: "command.forkAgentConversationNewTab.title", defaultValue: "Fork Conversation to New Tab")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "tab", "same", "pane"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.forkAgentConversationNewWorkspace",
                title: constant(String(localized: "command.forkAgentConversationNewWorkspace.title", defaultValue: "Fork Conversation to New Workspace")),
                subtitle: workspaceSubtitle,
                keywords: ["terminal", "agent", "fork", "conversation", "session", "claude", "codex", "opencode", "new", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "right"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "down"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    !$0.bool(CommandPaletteContextKeys.browserDisabled)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )
    }
}
