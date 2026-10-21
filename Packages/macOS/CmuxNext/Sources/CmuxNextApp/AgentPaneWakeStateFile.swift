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
    /// Attachments carry their contents: a tab holding more is not kept, and the file stops growing
    /// past ``maximumBytes`` (a larger file is not read).
    nonisolated static let maximumTabBytes = 4 * 1024 * 1024
    nonisolated static let maximumBytes = 8 * 1024 * 1024

    let file: URL?

    init(file: URL?) {
        self.file = file
    }

    /// The file next to the launch snapshot of `snapshot` (the tag's state).
    convenience init(beside snapshot: SidebarSnapshotFile?) {
        self.init(file: snapshot?.url.deletingLastPathComponent().appending(path: Self.fileName))
    }

    /// The last quit's states, by tab, once: the file goes, so a crash later in this run never
    /// brings back chips already sent.
    func take() -> [String: AgentPaneWakeState] {
        guard let file else { return [:] }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maximumBytes,
              // concurrency-allow: one capped read of a local state file when the tab store is made
              let data = try? Data(contentsOf: file),
              let states = try? JSONDecoder().decode([String: AgentPaneWakeState].self, from: data) else { return [:] }
        return states.filter { !$0.value.isEmpty }
    }

    /// Replaces the saved states with `states` (by tab key); with none held the file goes.
    func save(_ states: [String: AgentPaneWakeState]) async {
        guard let file else { return }
        let held = states.filter { !$0.value.isEmpty }
        await Task.detached { Self.write(held, to: file) }.value
    }

    private nonisolated static func write(_ states: [String: AgentPaneWakeState], to file: URL) {
        let encoder = JSONEncoder()
        var kept: [String: AgentPaneWakeState] = [:]
        var total = 0
        // Smallest first, so one tab's large attachments never cost every other tab its composer.
        let sized = states.compactMap { key, state in (try? encoder.encode(state)).map { (key, state, $0.count) } }
        for (key, state, size) in sized.sorted(by: { $0.2 < $1.2 }) where size <= maximumTabBytes && total + size <= maximumBytes {
            kept[key] = state
            total += size
        }
        guard !kept.isEmpty, let data = try? encoder.encode(kept) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
    }
}
