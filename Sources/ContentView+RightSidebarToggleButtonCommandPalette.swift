import CmuxCommandPalette
import CmuxSettings
import Foundation

/// Command palette entries that switch `rightSidebar.toggleButton` live.
///
/// Each command writes the same UserDefaults key that `cmux.json` manages, so
/// every window updates at once. A later edit of `cmux.json` wins again.
extension RightSidebarToggleButtonPlacement {
    var commandPaletteCommandId: String {
        "palette.rightSidebarToggleButton.\(rawValue)"
    }

    /// Localized name of the placement, shared by the palette and debug menu.
    var localizedTitle: String {
        switch self {
        case .titlebar:
            return String(localized: "rightSidebar.toggleButton.placement.titlebar", defaultValue: "Window Corner")
        case .paneTabBar:
            return String(localized: "rightSidebar.toggleButton.placement.paneTabBar", defaultValue: "Pane Tab Bar")
        case .sidebarFooter:
            return String(localized: "rightSidebar.toggleButton.placement.sidebarFooter", defaultValue: "Left Sidebar Footer")
        case .hidden:
            return String(localized: "rightSidebar.toggleButton.placement.hidden", defaultValue: "Hidden")
        }
    }

    /// Makes this placement the active one for every window.
    func apply(defaults: UserDefaults = .standard) {
        SettingCatalog().rightSidebar.toggleButton.set(self, in: defaults)
    }
}

extension ContentView {
    static func commandPaletteRightSidebarToggleButtonContributions() -> [CommandPaletteCommandContribution] {
        RightSidebarToggleButtonPlacement.allCases.map { placement in
            let title = String.localizedStringWithFormat(
                String(localized: "command.rightSidebarToggleButton.title", defaultValue: "Right Sidebar Button: %@"),
                placement.localizedTitle
            )
            let subtitle = String(localized: "command.rightSidebarToggleButton.subtitle", defaultValue: "View")
            return CommandPaletteCommandContribution(
                commandId: placement.commandPaletteCommandId,
                title: { _ in title },
                subtitle: { _ in subtitle },
                keywords: ["right", "sidebar", "toggle", "button", "placement", "titlebar", "corner", "tab bar", "footer", "hide"]
            )
        }
    }

    func registerRightSidebarToggleButtonCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for placement in RightSidebarToggleButtonPlacement.allCases {
            registry.register(commandId: placement.commandPaletteCommandId) {
                placement.apply()
            }
        }
    }
}
