public import Foundation

/// A new chat's typed text from before it has an acpmux session (cx-z5vd), by tab, in a JSON file
/// beside the launch snapshot: after a relaunch that tab opens as the chat with its draft, not as
/// the New Tab page. Once the chat has a session acpmux keeps its draft, and this copy is gone.
public final class AgentUnsentDrafts {
    public static let fileName = "agent-unsent-drafts.json"
    /// A longer text is not kept (acpmux's own draft limit).
    static let maximumCharacters = 1_000_000

    let file: URL?
    public struct Record: Codable, Equatable, Sendable {
        public var text: String
        public var attachments: [AgentPaneWakeState.Attachment]
    }
    private var drafts: [String: Record]

    public init(file: URL?) {
        self.file = file
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        drafts = data.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) }
            ?? data.flatMap { (try? JSONDecoder().decode([String: String].self, from: $0))?.mapValues { Record(text: $0, attachments: []) } }
            ?? [:]
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// Tab `key`'s kept text as a new chat's seed; nil for a tab whose chat has a session, or
    /// (`local` false) one on another machine.
    public func seed(for key: String, session: String?, local: Bool = true) -> AgentPaneSeedSource? {
        guard local, session == nil, let record = drafts[key] else { return nil }
        return AgentPaneSeedSource(AgentPaneSeed(
            draft: record.text.isEmpty ? nil : record.text,
            draftAttachments: record.attachments,
        ))
    }

    /// Keeps the typed text of `model`'s chat for the tab `key` names when it runs, until the chat
    /// has a session. Call it after the tab's own `onSessionChange` is set.
    public func wire(_ model: AgentPaneModel, key: @escaping () -> String) {
        model.onUnsentDraft = { [weak self] text, attachments in self?.set(text, attachments: attachments, for: key()) }
        model.onUnsentDraftTextOnly = { [weak self] text in self?.setTextPreservingAttachments(text, for: key()) }
        let started = model.onSessionChange
        model.onSessionChange = { [weak self] session in
            self?.set("", for: key())
            started?(session)
        }
    }

    /// Whether tab `key` holds a new chat's typed text (its close earns an undo toast).
    public func hasDraft(_ key: String) -> Bool { drafts[key] != nil }
    public func attachments(for key: String) -> [AgentPaneWakeState.Attachment] { drafts[key]?.attachments ?? [] }

    /// Updates text without changing attachments received from an earlier attachment-aware write.
    public func setTextPreservingAttachments(_ text: String, for key: String) {
        set(text, attachments: drafts[key]?.attachments ?? [], for: key)
    }

    /// Keeps `text` as tab `key`'s draft; blank text forgets it.
    public func set(_ text: String, attachments: [AgentPaneWakeState.Attachment] = [], for key: String) {
        let keepText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= Self.maximumCharacters
        guard keepText || !attachments.isEmpty else {
            if drafts.removeValue(forKey: key) != nil { save() }
            return
        }
        let record = Record(text: keepText ? text : "", attachments: attachments)
        guard drafts[key] != record else { return }
        drafts[key] = record
        save()
    }

    /// The store gave provisional tab `key` its id `real`.
    public func move(_ key: String, to real: String) {
        guard key != real, let record = drafts.removeValue(forKey: key) else { return }
        drafts[real] = record
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
