import AppKit
import CmuxCommandPalette
import Foundation

extension CommandPaletteContextKeys {
    /// Whether a multiplayer share session is currently active.
    static let shareSessionActive = CommandPaletteContextKeys(rawValue: "share.sessionActive")
}

extension ContentView {
    static func commandPaletteShareCommandContributions(
        isFeatureEnabled: Bool
    ) -> [CommandPaletteCommandContribution] {
        guard isFeatureEnabled else { return [] }

        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.shareWorkspaces",
                title: constant(String(
                    localized: "command.shareWorkspaces.title",
                    defaultValue: "Share Workspace…"
                )),
                subtitle: constant(String(localized: "command.share.subtitle", defaultValue: "Share")),
                keywords: ["share", "multiplayer", "collab", "collaborate", "invite", "session", "live"],
                when: { !$0.bool(CommandPaletteContextKeys.shareSessionActive) }
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.showShareSession",
                title: constant(String(
                    localized: "share.chat.title",
                    defaultValue: "Share Session"
                )),
                subtitle: constant(String(localized: "command.share.subtitle", defaultValue: "Share")),
                keywords: ["share", "multiplayer", "chat", "session", "participants"],
                when: { $0.bool(CommandPaletteContextKeys.shareSessionActive) },
                enablement: { $0.bool(CommandPaletteContextKeys.shareSessionActive) }
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
            guard CmuxFeatureFlags.shared.isMultiplayerShareUIEnabled else { return }
            guard let focusedWorkspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            shareSessionController.startSharing(
                tabManager: tabManager,
                focusedWorkspace: focusedWorkspace
            )
        }
        registry.register(commandId: "palette.stopSharing") {
            guard CmuxFeatureFlags.shared.isMultiplayerShareUIEnabled else { return }
            shareSessionController.stopSharing()
        }
        registry.register(commandId: "palette.showShareSession") {
            guard CmuxFeatureFlags.shared.isMultiplayerShareUIEnabled else { return }
            shareSessionController.showSessionPanel()
        }
    }
}
