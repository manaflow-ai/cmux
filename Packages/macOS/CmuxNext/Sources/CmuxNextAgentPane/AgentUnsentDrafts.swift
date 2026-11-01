public import Foundation
import os
import CmuxNextCompat

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
///
/// A kept draft is never lost to a load: until a page has been handed tab `key`'s draft
/// (``seed(for:session:local:)``), the page's empty text is a page that has not loaded it yet, not a
/// clear, and is ignored; its non-empty text is merged with the kept one (the kept text first, the
/// typed text after it), never written over it. Once the page has it, the page's text is the draft,
/// and an empty one (the person deleted it, or sent it) clears it. A file this run cannot read is
/// set aside, never replaced by an empty or a partial one.
public final class AgentUnsentDrafts {
    public static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit, `Hub::MAX_COMPOSER_DRAFT_CHARS`; the web's
    /// composerDraft.ts `MAX_DRAFT_CHARS`, pinned equal by composer-draft-orderings.test.tsx).
    public static let maximumCharacters = 1_000_000

    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.unsent-drafts")
    let file: URL?
    /// Saves leave the main thread: typing in a new chat saves every settled edit.
    private let store: AgentPaneStateFile?
    private var drafts: [String: String]
    /// Tabs whose draft came from the file and no page has been handed yet.
    /// (Each with the draft the file held: what the page's text merges with until it takes the seed.)
    private var undelivered: [String: String]
    /// The file exists but could not be read: the first save that runs sets it aside first.
    private let unreadable: UnreadableFile

    /// - Parameter files: The app's state files (`AppServices`), so the file has one writer.
    public init(file: URL?, files: AgentPaneStateFiles) {
        self.file = file
        store = file.map(files.at)
        drafts = [:]
        undelivered = [:]
        unreadable = UnreadableFile()
        guard let store else { return }
        let data = store.read()
        if let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            drafts = decoded
            undelivered = decoded
        } else {
            // No file, or one this run could not read or decode: the first save, on the file's queue
            // (no disk check here, on the main thread), sets aside whatever file is there by then.
            unreadable.pending.withLock { $0 = true }
            if data != nil { Self.logger.error("unsent drafts unreadable; set aside on the next write") }
        }
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?, files: AgentPaneStateFiles) {
        self.init(file: directory?.appending(path: Self.fileName), files: files)
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine. Once the page takes it (its handshake), it is the
    /// page's: its empty text clears it. Until then the tab still waits for it, so a stand-in page
    /// (a host that failed before its handshake) cannot clear it with its empty prompt. Before
    /// (cmux#28204 review at 3da4b376), making the seed counted as delivered.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let text = drafts[key] else { return nil }
        let source = AgentPaneSeedSource(AgentPaneSeed(draft: text))
        source.onDraftTaken = { [weak self] in _ = self?.undelivered.removeValue(forKey: key) }
        return source
    }

    /// Keeps the typed text of `model`'s chat for the tab `key` names when it runs, until the chat
    /// has a session. Call it after the tab's own `onSessionChange` is set.
    public func wire(_ model: AgentPaneModel, key: @escaping () -> String) {
        model.onUnsentDraft = { [weak self] text in self?.typed(text, for: key()) }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds a new chat's typed text (its close earns an undo toast).
    public func hasDraft(_ key: String) -> Bool { drafts[key] != nil }

    /// Tab `key`'s kept text, if any.
    public func draft(for key: String) -> String? { drafts[key] }

    /// The page of tab `key` sent its text (`chat.unsentDraft`). Until the page takes the kept
    /// draft (its seed, ``seed(for:session:local:)``), each text it sends is only its typing: it is
    /// merged with the draft the file held, and an empty one leaves that draft as it was. Before
    /// (cmux#28204 review at 027ee470), the first text counted as delivery, so a second ("x", then
    /// "xy") replaced the merge and lost the kept draft.
    public func typed(_ text: String, for key: String) {
        guard let kept = undelivered[key] else {
            set(text, for: key)
            return
        }
        // A merge past the limit is refused (`set`): the tab keeps what it had.
        set(Self.isBlank(text) ? kept : Self.merged(typed: text, kept: kept), for: key)
    }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it (the tab's chat started or closed,
    /// or its page cleared a draft it had). A text past ``maximumCharacters`` is refused, as acpmux
    /// refuses one: the tab keeps the draft it had. Before (cmux#28204 review at b7cddbbf), it was
    /// taken as no draft, so a merge past the limit removed the saved draft.
    /// Returns false when the text was refused.
    @discardableResult
    public func set(_ text: String, for key: String) -> Bool {
        guard text.unicodeScalars.count <= Self.maximumCharacters else {
            Self.logger.error("unsent draft past the limit not kept; the previous one stays")
            return false
        }
        let value = Self.isBlank(text) ? nil : text
        guard drafts[key] != value else { return true }
        drafts[key] = value
        if value == nil { undelivered.removeValue(forKey: key) }
        save()
        return true
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard key != real, let text = drafts.removeValue(forKey: key) else { return }
        drafts[real] = text
        if let kept = undelivered.removeValue(forKey: key) { undelivered[real] = kept }
        save()
    }

    /// The kept text first, then the typed text after it (as the page merges them,
    /// composerDraft.ts `mergedDraft`), only for text the page sent before it was handed the kept
    /// draft. Dedupe is exact only: the same text, or one that is already this merge's result. Never
    /// by substring: a kept "bug" and a typed "debugging" are both kept.
    public static func merged(typed: String, kept: String) -> String {
        if typed == kept { return typed }
        if typed.hasPrefix(kept + "\n\n") { return typed }
        if kept.hasSuffix("\n\n" + typed) { return kept }
        return kept + "\n\n" + typed
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let store else { return }
        let drafts = drafts
        let unreadable = unreadable
        let url = store.url
        store.write {
            // On the file's queue, before the write: an unreadable file is kept beside it, so what
            // it held can still be recovered; a failed move throws, which leaves the file as it is.
            try unreadable.setAside(url)
            return drafts.isEmpty ? nil : try JSONEncoder().encode(drafts)
        }
    }

    /// Whether the file still has to be set aside before a save; shared with the file's queue.
    nonisolated private final class UnreadableFile: Sendable {
        let pending = Mutex<Bool>(false)

        /// Runs on the file's queue only. The file this store could not read when it loaded is moved
        /// beside it before the first save, even when it reads now: this store never loaded what it
        /// holds, so writing over it would lose those drafts. Before (cmux#28204 review at c736d691),
        /// a file that decoded on the retry (a read that failed once) was written over.
        func setAside(_ url: URL) throws {
            guard pending.withLock({ $0 }) else { return }
            let files = FileManager.checked
            if files.fileExists(atPath: url.path) {
                let aside = url.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                    .appendingPathExtension(url.pathExtension)
                do {
                    try files.moveItem(at: url, to: aside)
                } catch {
                    AgentUnsentDrafts.logger.error("unsent drafts not saved: the unreadable file could not be set aside")
                    throw error
                }
            }
            pending.withLock { $0 = false }
        }
    }
}
