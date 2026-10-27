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
    /// Writes the drafts off the main thread; nil keeps nothing on disk.
    private let writer: StateFileWriter?
    private var drafts: [String: String]

    /// - Parameters:
    ///   - file: The JSON file; nil keeps nothing.
    ///   - work: The app's blocking-work lanes, where each save is encoded and written; nil keeps nothing.
    ///   - write: Puts a save on disk, on a lane thread; default the disk (tests record where it runs).
    public init(file: URL?, work: BackgroundWork?, write: @escaping StateFileWriter.Write = StateFileWriter.disk) {
        self.file = file
        writer = file.flatMap { file in work.map { StateFileWriter(file: file, work: $0, write: write) } }
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        drafts = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?, work: BackgroundWork) {
        self.init(file: directory?.appending(path: Self.fileName), work: work)
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

    /// Returns once every save so far is on disk (tests; the quit awaits the lanes instead).
    public func flushed() async {
        await writer?.flushed()
    }

    /// Hands the drafts to the writer: encoded and written on the files lane, never on the main thread
    /// (a draft holds up to a million characters); an empty set removes the file.
    private func save() {
        let drafts = drafts
        writer?.save { drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }
    }
}
