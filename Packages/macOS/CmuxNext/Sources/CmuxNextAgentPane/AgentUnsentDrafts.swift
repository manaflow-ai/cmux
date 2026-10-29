import CmuxNextCompat
public import Foundation

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
public final class AgentUnsentDrafts {
    public static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    let file: URL?
    /// Observed one tab at a time (perf-speed-of-light.md I2): a pane snapshot's title and the oracle's agents
    /// facet read their own tab's text, so typing in another tab's new chat re-runs neither.
    private let drafts = ObservedMap<String, String>()

    public init(file: URL?) {
        self.file = file
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        let saved = data.flatMap { try? JSONDecoder().blockingDecode([String: String].self, from: $0) } ?? [:]
        for (key, text) in saved { drafts[key] = text }
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let text = drafts[key] else { return nil }
        return AgentPaneSeedSource(AgentPaneSeed(draft: text))
    }

    /// Keeps the typed text of `model`'s chat for the tab `key` names when it runs, until the chat
    /// has a session. Call it after the tab's own `onSessionChange` is set.
    public func wire(_ model: AgentPaneModel, key: @escaping () -> String) {
        model.onUnsentDraft = { [weak self] text in self?.set(text, for: key()) }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds a new chat's typed text (its close earns an undo toast).
    public func hasDraft(_ key: String) -> Bool { drafts[key] != nil }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it.
    public func set(_ text: String, for key: String) {
        let keep = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumCharacters
        let value = keep ? text : nil
        guard drafts[key] != value else { return }
        drafts[key] = value
        save()
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard key != real, let text = drafts.removeValue(forKey: key) else { return }
        drafts.compact { $0 != key }
        drafts[real] = text
        save()
    }

    /// Tab `key` closed: its text goes, with its observed slot (a closed tab has no reader left).
    public func forget(_ key: String) {
        set("", for: key)
        drafts.compact { $0 != key }
    }

    private func save() {
        guard let file else { return }
        let saved = Dictionary(drafts.entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        // concurrency-allow: one small atomic write per settled edit of a new chat's text
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }
}
