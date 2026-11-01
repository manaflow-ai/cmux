import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
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
    /// The fixture Mac a showcase run names (`--showcase`, the capture scenes).
    static let showcaseMachineName = MacName.captureName

    /// This Mac's name on its panes and for other Macs: `read` answers it, except in a showcase run,
    /// which names the fixture Mac and never reads the host's, so a capture shows no real computer name.
    static func localMachineName(showcase: Bool, read: () async -> String) async -> String {
        showcase ? showcaseMachineName : await read()
    }

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
