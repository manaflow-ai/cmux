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


// MARK: - Command Palette Command Contributions
extension ContentView {
    func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        func markdownPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.markdownWithName", defaultValue: "Markdown • \(name)")
        }

        func workspaceColorCommandTitle(_ paletteName: String) -> String {
            switch paletteName {
            case "Red":
                return String(localized: "shortcut.setWorkspaceColorRed.label", defaultValue: "Workspace Color: Red")
            case "Crimson":
                return String(localized: "shortcut.setWorkspaceColorCrimson.label", defaultValue: "Workspace Color: Crimson")
            case "Orange":
                return String(localized: "shortcut.setWorkspaceColorOrange.label", defaultValue: "Workspace Color: Orange")
            case "Amber":
                return String(localized: "shortcut.setWorkspaceColorAmber.label", defaultValue: "Workspace Color: Amber")
            case "Olive":
                return String(localized: "shortcut.setWorkspaceColorOlive.label", defaultValue: "Workspace Color: Olive")
            case "Green":
                return String(localized: "shortcut.setWorkspaceColorGreen.label", defaultValue: "Workspace Color: Green")
            case "Teal":
                return String(localized: "shortcut.setWorkspaceColorTeal.label", defaultValue: "Workspace Color: Teal")
            case "Aqua":
                return String(localized: "shortcut.setWorkspaceColorAqua.label", defaultValue: "Workspace Color: Aqua")
            case "Blue":
                return String(localized: "shortcut.setWorkspaceColorBlue.label", defaultValue: "Workspace Color: Blue")
            default:
                return String(
                    localized: "command.workspaceColor.named",
                    defaultValue: "Workspace Color: \(paletteName)"
                )
            }
        }

        var contributions: [CommandPaletteCommandContribution] = []

        appendCommandPaletteGlobalContributions(to: &contributions)

        appendCommandPaletteWorkspaceContributions(
            to: &contributions,
            workspaceSubtitle: workspaceSubtitle,
            workspaceColorCommandTitle: workspaceColorCommandTitle
        )
        appendIdentifierCopyCommandContributions(
            to: &contributions,
            workspaceSubtitle: workspaceSubtitle,
            panelSubtitle: panelSubtitle
        )

        appendCommandPalettePanelContributions(
            to: &contributions,
            panelSubtitle: panelSubtitle
        )

        appendCommandPaletteBrowserContributions(
            to: &contributions,
            workspaceSubtitle: workspaceSubtitle,
            browserPanelSubtitle: browserPanelSubtitle,
            markdownPanelSubtitle: markdownPanelSubtitle
        )

        appendCommandPaletteTerminalContributions(
            to: &contributions,
            workspaceSubtitle: workspaceSubtitle,
            terminalPanelSubtitle: terminalPanelSubtitle
        )

        appendCommandPaletteCmuxConfigContributions(to: &contributions)

        return contributions
    }
}
