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
    /// Reads through the shared file seam, including any saves made by its legacy queue.
    private let store: AgentPaneStateFile?
    private var drafts: [String: String]
    private var finishing = false
    private var pendingIdentities: Set<String> = []
    private var identityWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - file: The JSON file; nil keeps nothing.
    ///   - work: The app's blocking-work lanes, where each save is encoded and written; nil keeps nothing.
    ///   - write: Puts a save on disk, on a lane thread; default the disk (tests record where it runs).
    public init(file: URL?, work: BackgroundWork?, write: @escaping StateFileWriter.Write = StateFileWriter.disk) {
        self.file = file
        writer = file.flatMap { file in work.map { StateFileWriter(file: file, work: $0, write: write) } }
        store = file.map(AgentPaneStateFile.at)
        let data = store?.read()
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
        model.onUnsentDraft = { [weak self] text in self?.set(text, for: key()) ?? false }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds a new chat's typed text (its close earns an undo toast).
    public func hasDraft(_ key: String) -> Bool { drafts[key] != nil }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it.
    @discardableResult
    public func set(_ text: String, for key: String) -> Bool {
        guard !finishing else { return false }
        let keep = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumCharacters
        let value = keep ? text : nil
        guard drafts[key] != value else { return true }
        drafts[key] = value
        save()
        return true
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard key != real, !finishing || pendingIdentities.contains(key) else { return }
        if let text = drafts.removeValue(forKey: key) {
            drafts[real] = text
            save()
        }
        settledIdentity(key)
    }

    /// A tab shown under `key` is still being created. Quit waits for its accepted draft's real id.
    public func expectIdentity(_ key: String) {
        guard !finishing else { return }
        pendingIdentities.insert(key)
    }

    /// The pending tab closed or failed to be created, so no restored tab can use its draft.
    public func abandonIdentity(_ key: String) {
        guard pendingIdentities.contains(key) else { return }
        if drafts.removeValue(forKey: key) != nil { save() }
        settledIdentity(key)
    }

    /// Returns once every save so far is on disk (tests; the quit awaits the lanes instead).
    public func flushed() async {
        await writer?.flushed()
    }

    /// Refuses new edits immediately; accepted drafts may still follow an in-flight tab creation.
    func finishSaving() {
        finishing = true
        pendingIdentities.formIntersection(drafts.keys)
    }

    /// Quit settles accepted drafts' identities before it starts the final lane drain.
    func identitiesSettled() async {
        guard !pendingIdentities.isEmpty else { return }
        await withCheckedContinuation { identityWaiters.append($0) }
    }

    private func settledIdentity(_ key: String) {
        pendingIdentities.remove(key)
        guard pendingIdentities.isEmpty else { return }
        let waiters = identityWaiters
        identityWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Hands the drafts to the writer: encoded and written on the files lane, never on the main thread
    /// (a draft holds up to a million characters); an empty set removes the file.
    private func save() {
        let drafts = drafts
        writer?.save { drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }
    }
}
