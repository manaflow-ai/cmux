import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static let moveAgentConversationToCloudCommandId = "palette.moveAgentConversationToCloud"
    /// True when the focused terminal runs a local Claude that Move to Cloud can take.
    static let panelHasMovableClaudeAgentContextKey = CommandPaletteContextKeys(rawValue: "panel.hasMovableClaudeAgent")

    /// Moves the focused terminal's Claude to Cloud through
    /// ``SessionMoveToCloudAction``, the path the workspace and terminal menus use.
    static func commandPaletteMoveToCloudContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: moveAgentConversationToCloudCommandId,
                title: { _ in
                    String(localized: "command.moveAgentConversationToCloud.title", defaultValue: "Move Conversation to Cloud")
                },
                subtitle: subtitle,
                keywords: ["terminal", "agent", "move", "conversation", "session", "claude", "cloud", "machine", "vm", "remote", "handoff"],
                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                        $0.bool(panelHasMovableClaudeAgentContextKey)
                }
            ),
        ]
    }

    static func setCommandPaletteMoveToCloudContext(
        workspace: Workspace,
        panelId: UUID,
        in snapshot: inout CommandPaletteContextSnapshot
    ) {
        snapshot.setBool(
            panelHasMovableClaudeAgentContextKey,
            SessionMoveToCloudAction.shared.canMove(workspace: workspace, panelId: panelId) != nil
        )
    }

    func registerMoveToCloudCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.moveAgentConversationToCloudCommandId) {
            guard let panelContext = focusedPanelContext,
                  SessionMoveToCloudAction.shared.move(
                      workspace: panelContext.workspace,
                      panelId: panelContext.panelId,
                      machine: nil
                  ) != nil else {
                NSSound.beep()
                return
            }
        }
    }
}
