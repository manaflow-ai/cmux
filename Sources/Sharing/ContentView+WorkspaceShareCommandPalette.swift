import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static let commandPaletteWorkspaceShareCommandID = "palette.workspace.share"

    static func commandPaletteWorkspaceShareCommandContributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: commandPaletteWorkspaceShareCommandID,
                title: { _ in
                    String(
                        localized: "command.workspaceShare.title",
                        defaultValue: "Share Workspace"
                    )
                },
                subtitle: { _ in
                    String(
                        localized: "command.workspaceShare.subtitle",
                        defaultValue: "Collaboration"
                    )
                },
                keywords: ["share", "workspace", "multiplayer", "collaborate", "cursor", "chat"],
                when: { context in context.bool(CommandPaletteContextKeys.hasWorkspace) }
            ),
        ]
    }

    func registerWorkspaceShareCommandHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteWorkspaceShareCommandID) {
            guard let workspaceID = tabManager.selectedWorkspace?.id,
                  let coordinator = AppDelegate.shared?.workspaceShareCoordinator else {
                NSSound.beep()
                return
            }
            coordinator.share(workspaceID: workspaceID, tabManager: tabManager)
        }
    }
}
