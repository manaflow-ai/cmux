import AppKit
import CmuxCommandPalette
import Foundation

extension ContentView {
    static let moveAgentConversationToCloudCommandId = "palette.moveAgentConversationToCloud"
    /// True when the focused terminal runs a local Claude that Move to Cloud can take.
    static let panelHasMovableClaudeAgentContextKey = CommandPaletteContextKeys(rawValue: "panel.hasMovableClaudeAgent")

    static func commandPaletteMoveToCloudContributions(
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        []
    }
}
