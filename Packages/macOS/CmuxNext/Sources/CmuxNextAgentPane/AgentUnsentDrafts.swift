public import Foundation
import os

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
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.unsent-drafts")
    let file: URL?
    /// Saves leave the main thread: typing in a new chat saves every settled edit.
    private let store: AgentPaneStateFile?
    private var drafts: [String: String]
    /// Tabs whose draft came from the file and no page has been handed yet.
    private var undelivered: Set<String>
    /// The file exists but could not be read: it is set aside before the first write.
    private var unreadable = false

    public init(file: URL?) {
        self.file = file
        drafts = [:]
        undelivered = []
        store = file.map(AgentPaneStateFile.at)
        guard let file, let store else { return }
        // The store's read waits for the saves already queued for this file (another store of it).
        guard let data = store.read() else {
            // concurrency-allow: one existence check when the tab store is made and no file was read
            if FileManager.default.fileExists(atPath: file.path) {
                unreadable = true
                Self.logger.error("unsent drafts unreadable; set aside on the next write")
            }
            return
        }
        do {
            drafts = try JSONDecoder().decode([String: String].self, from: data)
            undelivered = Set(drafts.keys)
        } catch {
            unreadable = true
            Self.logger.error("unsent drafts unreadable; set aside on the next write: \(String(describing: error), privacy: .public)")
        }
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine. A seed given out is the page's from then on: its
    /// empty text clears it.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let text = handOut(key) else { return nil }
        return AgentPaneSeedSource(AgentPaneSeed(draft: text))
    }

    /// Tab `key`'s kept text for a page that builds its own seed (Start Agent's panel), given out as
    /// ``seed(for:session:local:)`` gives it: from then on the page's empty text clears it.
    public func handOut(_ key: String) -> String? {
        guard let text = drafts[key] else { return nil }
        undelivered.remove(key)
        return text
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

    /// The page of tab `key` sent its text (`chat.unsentDraft`). Before the page was handed the
    /// kept draft, an empty text is ignored and a different one is merged with it.
    public func typed(_ text: String, for key: String) {
        guard undelivered.contains(key), let kept = drafts[key] else { return set(text, for: key) }
        guard !Self.isBlank(text) else { return }
        undelivered.remove(key)
        set(Self.merged(typed: text, kept: kept), for: key)
    }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it (the tab's chat started or closed,
    /// or its page cleared a draft it had).
    public func set(_ text: String, for key: String) {
        let keep = !Self.isBlank(text) && text.count <= Self.maximumCharacters
        let value = keep ? text : nil
        guard drafts[key] != value else { return }
        drafts[key] = value
        if value == nil { undelivered.remove(key) }
        save()
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard key != real, let text = drafts.removeValue(forKey: key) else { return }
        drafts[real] = text
        if undelivered.remove(key) != nil { undelivered.insert(real) }
        save()
    }

    /// The kept text first, then the typed text after it (as the page merges them,
    /// composerDraft.ts `mergedDraft`); a text that already holds the other is kept as it is.
    public static func merged(typed: String, kept: String) -> String {
        if typed.contains(kept) { return typed }
        if kept.hasSuffix("\n\n" + typed) { return kept }
        return kept + "\n\n" + typed
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let file, let store else { return }
        if unreadable {
            // Kept beside it, so whatever it held can still be recovered; never overwritten. No
            // save of this store was queued before this one, so the rename runs ahead of every save.
            // concurrency-allow: one rename, only on the first save after an unreadable file was found
            if FileManager.default.fileExists(atPath: file.path) {
                let aside = file.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                    .appendingPathExtension(file.pathExtension)
                do {
                    try FileManager.default.moveItem(at: file, to: aside)
                } catch {
                    Self.logger.error("unsent drafts not saved: the unreadable file could not be set aside")
                    return
                }
            }
            unreadable = false
        }
        let drafts = drafts
        store.write { drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }
    }
}
