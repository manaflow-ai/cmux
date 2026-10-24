public import Foundation

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
public final class AgentUnsentDrafts {
    public nonisolated static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    let file: URL?
    private var drafts: [String: String]

    /// The drafts `drafts`, saved to `file` from now on.
    /// - Parameters:
    ///   - file: Where edits are saved; nil keeps them in memory.
    ///   - drafts: The drafts the last run saved there, read off the main thread at launch
    ///     (``read(_:)`` through the app's `LaunchFiles`).
    public init(file: URL?, drafts: [String: String]) {
        self.file = file
        self.drafts = drafts
    }

    /// The drafts in `file`, read now on the calling thread (tests, and a tab store made with no
    /// launch read).
    public convenience init(file: URL?) {
        self.init(file: file, drafts: Self.read(file))
    }

    /// The drafts saved in `file` (empty when there is none or it does not decode). Runs on any
    /// thread: the launch reads it on a background thread begun in `main` (#17587).
    public nonisolated static func read(_ file: URL?) -> [String: String] {
        // concurrency-allow: one read of a small local state file, off the main thread at launch
        let data = file.flatMap { try? Data(contentsOf: $0) }
        return data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public nonisolated static func file(in directory: URL?) -> URL? {
        directory?.appending(path: fileName)
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
