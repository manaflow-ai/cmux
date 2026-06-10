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


// MARK: - Command Palette cmux.json Command Contributions
extension ContentView {
    func appendCommandPaletteCmuxConfigContributions(to contributions: inout [CommandPaletteCommandContribution]) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let cmuxConfigDefaultSubtitle = String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json")
        for issue in cmuxConfigStore.configurationIssues {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: commandPaletteCmuxConfigIssueCommandID(issue),
                    title: constant(commandPaletteCmuxConfigIssueTitle(issue)),
                    subtitle: constant(commandPaletteCmuxConfigIssueSubtitle(issue)),
                    keywords: ["cmux", "config", "json", "schema", "error", "warning"]
                )
            )
        }
        for action in cmuxConfigStore.paletteCustomActions() {
            let actionTitle = sanitizeCmuxConfigPaletteText(action.title)
            let subtitleText = action.subtitle
                .map { sanitizeCmuxConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? cmuxConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: action.id,
                    title: constant(actionTitle),
                    subtitle: constant(subtitleText),
                    keywords: action.keywords
                )
            )
        }
    }
}
