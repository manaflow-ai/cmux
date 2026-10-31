public import Foundation
import os

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft; an empty generation tombstone stays here.
///
/// A kept draft is never lost to a load: until a page has been handed tab `key`'s draft
/// (``seed(for:session:local:)``), the page's empty text is a page that has not loaded it yet, not a
/// clear, and is ignored within the same generation; its non-empty text is merged with the kept
/// one. A newer generation replaces the text, including with an empty tombstone; older writes
/// are ignored. Once the page has it, the page's text is the draft,
/// and an empty one (the person deleted it, or sent it) clears it without forgetting its generation. A file this run cannot read is
/// set aside, never replaced by an empty or a partial one.
public final class AgentUnsentDrafts {
    public static let fileName = "agent-unsent-drafts.json"
    /// A longer text keeps only its first this many characters (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.unsent-drafts")
    let file: URL?
    /// Saves leave the main thread: typing in a new chat saves every settled edit.
    private let store: AgentPaneStateFile?
    private var drafts: [String: AgentUnsentDraft]
    /// Tabs whose draft came from the file and no page has been handed yet.
    private var undelivered: Set<String>
    /// The file exists but could not be read: it is set aside before the first write.
    private var unreadable = false
    /// Wiring must not wait on disk. Edits received before the file read finishes are kept and
    /// merged by generation when the read arrives.
    private var loaded = false
    private var localKeys = Set<String>()
    private var pendingSave = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether the initial state-file read has completed. A false value is normal during app
    /// wiring; seed sources wait for it before restoring a draft.
    public private(set) var isLoaded = false

    public init(file: URL?, loadSynchronously: Bool = true) {
        self.file = file
        drafts = [:]
        undelivered = []
        store = file.map(AgentPaneStateFile.at)
        guard let store else {
            loaded = true
            isLoaded = true
            return
        }
        if loadSynchronously {
            // Tests and explicit non-startup tools may use the old bounded read. App wiring passes
            // false below so startup never waits for disk or JSON decoding.
            finishLoading(store.readState())
        } else {
            // Do not make app wiring wait for disk or JSON decoding. The seed source below waits
            // for this read only when a page actually asks for its first draft.
            store.readStateAsync { [weak self] state in
                Task { @MainActor [weak self] in self?.finishLoading(state) }
            }
        }
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?, loadSynchronously: Bool = true) {
        self.init(file: directory?.appending(path: Self.fileName), loadSynchronously: loadSynchronously)
    }

    /// Waits for the first state-file read. Production restores use `seed(for:)`, while tests
    /// use this explicit barrier to make their assertions deterministic.
    public func waitUntilLoaded() async {
        if loaded { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadWaiters.append(continuation)
        }
    }

    private func finishLoading(_ state: AgentPaneStateFile.ReadState) {
        guard !loaded else { return }
        if case .readable(let data) = state {
            do {
                let disk = try JSONDecoder().decode([String: AgentUnsentDraft].self, from: data)
                for (key, incoming) in disk {
                    guard localKeys.contains(key), let local = drafts[key] else {
                        drafts[key] = incoming
                        undelivered.insert(key)
                        continue
                    }
                    if incoming.generation > local.generation {
                        drafts[key] = incoming
                        undelivered.insert(key)
                    } else if incoming.generation == local.generation,
                              !Self.isBlank(local.text), !Self.isBlank(incoming.text) {
                        drafts[key] = AgentUnsentDraft(
                            text: Self.merged(typed: local.text, kept: incoming.text),
                            generation: local.generation
                        )
                    }
                }
            } catch {
                unreadable = true
                Self.logger.error("unsent drafts unreadable; set aside on the next write: \(String(describing: error), privacy: .public)")
            }
        } else if case .unreadable = state {
            unreadable = true
            Self.logger.error("unsent drafts unreadable; set aside on the next write")
        }
        loaded = true
        isLoaded = true
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if pendingSave {
            pendingSave = false
            save()
        }
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine. A seed given out is the page's from then on: its
    /// empty text clears it.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil else { return nil }
        if loaded, handOut(key) == nil { return nil }
        return AgentPaneSeedSource { [weak self] in
            guard let self else { return nil }
            await self.waitUntilLoaded()
            guard let text = self.handOut(key) else { return nil }
            return AgentPaneSeed(draft: text, draftGeneration: self.generation(for: key))
        }
    }

    /// Tab `key`'s kept text for a page that builds its own seed (Start Agent's panel), given out as
    /// ``seed(for:session:local:)`` gives it: from then on the page's empty text clears it.
    public func handOut(_ key: String) -> String? {
        guard let draft = drafts[key] else { return nil }
        undelivered.remove(key)
        return draft.text
    }

    /// Keeps the typed text of `model`'s chat for the tab `key` names when it runs, until the chat
    /// has a session. Call it after the tab's own `onSessionChange` is set.
    public func wire(_ model: AgentPaneModel, key: @escaping () -> String) {
        model.onUnsentDraft = { [weak self] text, generation in self?.typed(text, for: key(), generation: generation) }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds text; an empty tombstone does not earn an undo toast.
    public func hasDraft(_ key: String) -> Bool { draft(for: key) != nil }

    public func draft(for key: String) -> String? {
        guard let draft = drafts[key], !Self.isBlank(draft.text) else { return nil }
        return draft.text
    }

    public func generation(for key: String) -> Int { drafts[key]?.generation ?? 0 }

    /// Missing generations are legacy generation zero, including after a relaunch. Only texts
    /// in the same generation may merge before handoff; a replacement never inherits old text.
    public func typed(_ text: String, for key: String, generation: Int? = nil) {
        let incoming = generation ?? 0
        let current = self.generation(for: key)
        if generation == nil, Self.isBlank(text), drafts[key] == nil { return }
        guard AgentUnsentDraft.valid(incoming), incoming >= current else { return }
        if incoming == current, undelivered.contains(key), let kept = drafts[key] {
            guard !Self.isBlank(text) else { return }
            undelivered.remove(key)
            set(Self.merged(typed: text, kept: kept.text), for: key, generation: incoming)
        } else {
            // A legacy clear still establishes a boundary; versioned pages advance it themselves.
            set(text, for: key, generation: generation == nil && Self.isBlank(text) ? nil : incoming)
        }
    }

    /// Native clear/send advances the generation. Explicit versioned writes reject old state.
    /// Empty values remain on disk, so neither late updates nor relaunch can revive sent text.
    public func set(_ text: String, for key: String, generation: Int? = nil) {
        let blank = Self.isBlank(text)
        let current = self.generation(for: key)
        let next = generation ?? (blank ? min(current + 1, AgentUnsentDraft.maximumGeneration) : current)
        guard AgentUnsentDraft.valid(next), next >= current else { return }
        let value = AgentUnsentDraft(text: blank ? "" : Self.capped(text), generation: next)
        guard drafts[key] != value else { return }
        drafts[key] = value
        localKeys.insert(key)
        if blank || next > current { undelivered.remove(key) }
        save()
    }

    /// The store gave provisional tab `key` its id `real`. Keep a tombstone at the old key too.
    public func move(_ key: String, to real: String) {
        guard key != real, let draft = drafts[key] else { return }
        if draft.generation >= generation(for: real) {
            drafts[real] = draft
            if undelivered.contains(key) { undelivered.insert(real) } else { undelivered.remove(real) }
        }
        drafts[key] = AgentUnsentDraft(text: "", generation: min(draft.generation + 1, AgentUnsentDraft.maximumGeneration))
        undelivered.remove(key)
        localKeys.insert(key)
        localKeys.insert(real)
        save()
    }

    /// Implements the merge contract documented at webviews/src/agent-session/acpmux/composerDraft.ts.
    /// Both implementations are checked against webviews/test/fixtures/composer-draft-merge.json.
    public static func merged(typed: String, kept: String, typedGeneration: Int = 0, keptGeneration: Int = 0) -> String {
        if typedGeneration > keptGeneration { return typed }
        if keptGeneration > typedGeneration { return kept }
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

    private func save() {
        guard let store else { return }
        guard loaded else {
            pendingSave = true
            return
        }
        if unreadable {
            store.preserveUnreadableFile()
            unreadable = false
        }
        let drafts = drafts
        store.write { drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }
    }
}
