import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
public final class AgentUnsentDrafts {
    public static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    let file: URL?
    private var drafts: [String: String]
    private let work: BackgroundWork
    private var acceptsWrites = true

    public init(file: URL?, work: BackgroundWork = BackgroundWork()) {
        self.file = file
        self.work = work
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        drafts = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?, work: BackgroundWork = BackgroundWork()) {
        self.init(file: directory?.appending(path: Self.fileName), work: work)
    }

    /// Waits for this files lane's earlier saves without blocking the main actor.
    public func flush() async {
        await withCheckedContinuation { continuation in
            work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { continuation.resume() }
        }
    }

    /// Called only after quit is committed: stop page writes before draining their ordered saves.
    public func finalizeForQuit() async {
        acceptsWrites = false
        await flush()
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let text = drafts[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
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
    public func hasDraft(_ key: String) -> Bool { drafts[key].map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }

    /// Keeps `text` as tab `key`'s draft; blank text keeps a clear tombstone for migration.
    public func set(_ text: String, for key: String) {
        guard acceptsWrites else { return }
        let keep = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumCharacters
        let value = keep ? text : ""
        guard drafts[key] != value else { return }
        drafts[key] = value
        save()
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard acceptsWrites, key != real, let text = drafts[key], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[key] = ""
        drafts[real] = text
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(drafts) else { return }
        // Fixed priority keeps snapshots ordered; post registers the shutdown hold before returning.
        work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown) {
            do {
                try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.blockingWrite(to: file, options: .atomic)
                try FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { }
        }
    }
}
