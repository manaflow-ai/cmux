import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTabs
import Observation

/// A store-committed agent chat tab: its tab id (`TabModel.id`) and surface.
struct AgentTabCreated: Sendable, Equatable {
    var key: String
    var surface: SurfaceID
}

/// What the store answered a session bind.
enum AgentSessionBindOutcome: Equatable {
    case taken
    /// Another device changed the tab's chat first (`conversation_tab.session_conflict`).
    case conflict
    /// The bind did not reach the store or failed otherwise.
    case failed
}

extension AgentTabStore {
    /// `name` without control characters, cut to 255 bytes on a character boundary; nil when empty.
    static func displayName(_ name: String) -> String? {
        var result = ""
        for character in name where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard result.utf8.count + String(character).utf8.count <= 255 else { break }
            result.append(character)
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The tabs showing the new tab page, for observers (the tab strip).
@Observable final class NewTabPageIDs {
    var ids: Set<String> = []
}
