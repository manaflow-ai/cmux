import CmuxCommandPalette
import Foundation

extension CommandPaletteContextKeys {
    /// Whether a multiplayer share session is currently active.
    static let shareSessionActive = CommandPaletteContextKeys(rawValue: "share.sessionActive")
}

extension ContentView {
    static func commandPaletteShareCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.shareWorkspaces",
                title: constant(String(
                    localized: "command.shareWorkspaces.title",
                    defaultValue: "Share Workspaces…"
                )),
                subtitle: constant(String(localized: "command.share.subtitle", defaultValue: "Share")),
                keywords: ["share", "multiplayer", "collab", "collaborate", "invite", "session", "live"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.stopSharing",
                title: constant(String(
                    localized: "command.stopSharing.title",
                    defaultValue: "Stop Sharing"
                )),
                subtitle: constant(String(localized: "command.share.subtitle", defaultValue: "Share")),
                keywords: ["share", "multiplayer", "stop", "end", "session"],
                when: { $0.bool(CommandPaletteContextKeys.shareSessionActive) },
                enablement: { $0.bool(CommandPaletteContextKeys.shareSessionActive) }
            ),
        ]
    }

    func registerShareCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.shareWorkspaces") {
            ShareSessionController.shared.startSharing()
        }
        registry.register(commandId: "palette.stopSharing") {
            ShareSessionController.shared.stopSharing()
        }
    }
}
