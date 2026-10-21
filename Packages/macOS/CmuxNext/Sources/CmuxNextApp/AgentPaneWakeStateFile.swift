import CmuxNextAgentPane
import Foundation

/// What each agent chat's page held that acpmux does not (``AgentPaneWakeState``: the composer's
/// attachments, shell mode with its unrun command, where the transcript rested), by tab, in a JSON
/// file beside the launch snapshot. The quit's window step saves it (`QuitCoordinator`), so every
/// relaunch that goes through the quit (Restart to Update, SIGTERM's Quit and keep sessions,
/// Cmd-Q) keeps it; the next launch hands it to each tab's first page with its handshake.
/// The draft's text is acpmux's (#21509) and a new chat's is `AgentUnsentDrafts`'.
final class AgentPaneWakeStateFile {
    static let fileName = "agent-pane-wake-states.json"

    let file: URL?

    init(file: URL?) {
        self.file = file
    }

    /// The file next to the launch snapshot of `snapshot` (the tag's state).
    convenience init(beside snapshot: SidebarSnapshotFile?) {
        self.init(file: snapshot?.url.deletingLastPathComponent().appending(path: Self.fileName))
    }

    /// The last quit's states, by tab.
    func take() -> [String: AgentPaneWakeState] {
        [:]
    }

    /// Replaces the saved states with `states` (by tab key).
    func save(_ states: [String: AgentPaneWakeState]) async {}
}
