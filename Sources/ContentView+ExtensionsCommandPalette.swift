import AppKit
import CmuxCommandPalette
import CmuxDockExtensions

/// Command-palette surface for Dock TUI extensions: install/browse commands
/// plus one dynamic "open" command per installed launchable pane. The palette
/// rebuilds contributions and handlers on every open, so freshly installed
/// extensions appear without a restart.
extension ContentView {
    func extensionsCommandPaletteContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        let subtitle = constant(String(
            localized: "command.extensions.subtitle",
            defaultValue: "Extensions"
        ))

        var contributions: [CommandPaletteCommandContribution] = []
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.extensionsInstall",
                title: constant(String(
                    localized: "command.extensionsInstall.title",
                    defaultValue: "Extensions: Install from GitHub…"
                )),
                subtitle: subtitle,
                keywords: ["extension", "install", "github", "tui", "dock", "plugin", "add"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.extensionsBrowse",
                title: constant(String(
                    localized: "command.extensionsBrowse.title",
                    defaultValue: "Extensions: Browse Marketplace"
                )),
                subtitle: subtitle,
                keywords: ["extension", "marketplace", "browse", "community", "tui", "dock", "plugin"]
            )
        )
        for item in DockExtensionsRuntime.shared.launchablePaneItems {
            let titleFormat = String(
                localized: "command.extensionsOpenPane.title",
                defaultValue: "Extension: Open %@"
            )
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: Self.extensionsPaneCommandID(item.qualifiedId),
                    title: constant(String.localizedStringWithFormat(titleFormat, item.title)),
                    subtitle: subtitle,
                    keywords: ["extension", "open", "dock", "pane", item.title.lowercased()]
                )
            )
        }
        return contributions
    }

    func registerExtensionsCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.extensionsInstall") {
            DockExtensionsRuntime.shared.installCoordinator.promptForInstall()
        }
        registry.register(commandId: "palette.extensionsBrowse") {
            NSWorkspace.shared.open(DockExtensionsRuntime.marketplaceURL)
        }
        for item in DockExtensionsRuntime.shared.launchablePaneItems {
            let qualifiedId = item.qualifiedId
            registry.register(commandId: Self.extensionsPaneCommandID(qualifiedId)) {
                DockExtensionsRuntime.shared.openPaneOrBeep(qualifiedId: qualifiedId)
            }
        }
    }

    /// FNV-1a hashed command id, matching the workspace-color/extension-sidebar
    /// dynamic-command convention.
    static func extensionsPaneCommandID(_ qualifiedId: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in qualifiedId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "palette.extensionsOpenPane.\(String(hash, radix: 16))"
    }
}
