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
    /// A longer text keeps only its first this many characters (acpmux's own draft limit).
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
        guard let store else { return }
        // The store's read waits for the saves already queued for this file (another store of it).
        let loaded = store.readState()
        guard case .readable(let data) = loaded else {
            if case .unreadable = loaded {
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
    /// or its page cleared a draft it had). A text over the limit keeps its first
    /// ``maximumCharacters``: a draft is never dropped for its length (a merge can pass the limit).
    public func set(_ text: String, for key: String) {
        let value = Self.isBlank(text) ? nil : Self.capped(text)
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

    /// Implements the merge contract documented at webviews/src/agent-session/acpmux/composerDraft.ts.
    /// Both implementations are checked against webviews/test/fixtures/composer-draft-merge.json.
    public static func merged(typed: String, kept: String) -> String {
        if mergeBlank(kept) { return typed }
        if mergeBlank(typed) { return kept }
        let typedUnits = Array(typed.utf16)
        let keptUnits = Array(kept.utf16)
        if draftMatch(text: typedUnits, pattern: keptUnits).contains { return typed }
        let match = draftMatch(text: keptUnits, pattern: typedUnits)
        if match.contains { return kept }
        if match.overlap >= 2 {
            return String(decoding: keptUnits + typedUnits.dropFirst(match.overlap), as: UTF16.self)
        }
        return kept + "\n\n" + typed
    }

    // ECMAScript trim's whitespace set; Foundation's set also includes U+0085 and omits U+FEFF.
    private static func mergeBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A,
                 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
                true
            default:
                false
            }
        }
    }

    // KMP over UTF-16, so containment and overlap are linear and agree with the webview.
    private static func draftMatch(text: [UInt16], pattern: [UInt16]) -> (contains: Bool, overlap: Int) {
        var prefix = [Int](repeating: 0, count: pattern.count)
        var matched = 0
        for index in 1..<pattern.count {
            while matched > 0, pattern[index] != pattern[matched] { matched = prefix[matched - 1] }
            if pattern[index] == pattern[matched] { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        for unit in text {
            while matched > 0, unit != pattern[matched] { matched = prefix[matched - 1] }
            if unit == pattern[matched] { matched += 1 }
            if matched == pattern.count { return (true, matched) }
        }
        return (false, matched)
    }

    /// `text`, or its first ``maximumCharacters`` when it is longer.
    static func capped(_ text: String) -> String {
        text.count <= maximumCharacters ? text : String(text.prefix(maximumCharacters))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let store else { return }
        if unreadable {
            store.preserveUnreadableFile()
            unreadable = false
        }
        let drafts = drafts
        store.write { drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }
    }
}
