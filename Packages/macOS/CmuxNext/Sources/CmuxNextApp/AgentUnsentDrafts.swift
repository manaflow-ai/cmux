import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
final class AgentUnsentDrafts {
    static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    let file: URL?
    private var drafts: [String: String]

    init(file: URL?) {
        self.file = file
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        drafts = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The file next to the launch snapshot of `snapshot` (the tag's state).
    convenience init(beside snapshot: SidebarSnapshotFile?) {
        self.init(file: snapshot?.url.deletingLastPathComponent().appending(path: Self.fileName))
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine.
    func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let text = drafts[key] else { return nil }
        return AgentPaneSeedSource(AgentPaneSeed(draft: text))
    }

    /// Keeps the typed text of `model`'s chat for the tab `key` names when it runs, until the chat
    /// has a session. Call it after the tab's own `onSessionChange` is set.
    func wire(_ model: AgentPaneModel, key: @escaping () -> String) {
        model.onUnsentDraft = { [weak self] text in self?.set(text, for: key()) }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds a new chat's typed text (its close earns an undo toast).
    func hasDraft(_ key: String) -> Bool { drafts[key] != nil }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it.
    func set(_ text: String, for key: String) {
        let keep = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumCharacters
        let value = keep ? text : nil
        guard drafts[key] != value else { return }
        drafts[key] = value
        save()
    }

    /// The store gave provisional tab `key` its id `real`.
    func move(_ key: String, to real: String) {
        guard key != real, let text = drafts.removeValue(forKey: key) else { return }
        drafts[real] = text
        save()
    }

    private func save() {
        guard let file else { return }
        if drafts.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // concurrency-allow: one small atomic write per settled edit of a new chat's text
        try? JSONEncoder().encode(drafts).write(to: file, options: .atomic)
    }
}
