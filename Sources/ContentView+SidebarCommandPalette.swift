import AppKit
import CmuxExtensionKit

extension ContentView {
    static func commandPaletteSidebarProviderCommandContributions() -> [CommandPaletteCommandContribution] {
        func localized(_ text: CmuxExtensionLocalizedText) -> String {
            Bundle.main.localizedString(forKey: text.key, value: text.defaultValue, table: nil)
        }

        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return CmuxExtensionSidebarProviderDescriptor.builtInProviders.map { provider in
            CommandPaletteCommandContribution(
                commandId: Self.commandPaletteSidebarProviderCommandID(provider),
                title: constant(
                    String(
                        format: String(
                            localized: "command.sidebarProvider.title",
                            defaultValue: "Sidebar: %@"
                        ),
                        localized(provider.title)
                    )
                ),
                subtitle: constant(
                    provider.subtitle.map(localized(_:))
                        ?? String(localized: "command.sidebarProvider.subtitle", defaultValue: "Sidebar")
                ),
                keywords: [
                    "sidebar",
                    "workspace",
                    "extension",
                    "provider",
                    provider.id,
                    localized(provider.title),
                ]
            )
        }
    }

    static func commandPaletteSidebarProviderCommandID(
        _ provider: CmuxExtensionSidebarProviderDescriptor
    ) -> String {
        "palette.sidebarProvider.\(provider.id)"
    }

    func handleCommandPaletteSidebarProvider(_ provider: CmuxExtensionSidebarProviderDescriptor) {
        SidebarWorkspaceListStyleSettings.applyProviderDescriptor(provider)
    }
}
