// cmux: Up and Down in Home's message box recall the messages the person sent,
// like a shell's history (Lawrence 2026-10-19: "Up arrow ... like it is
// history, this is for the iMessage, chief ui stuff"). Not a vendored file.
import Foundation

/// The message box's history browse: Up steps to older sent messages, Down to
/// newer ones and then back to the draft the person was typing.
///
/// The entries are the person's own messages in the conversation's transcript,
/// newest first (``entries(in:)``), so the history is the conversation's own,
/// per Chief and across restarts, with no second store to drift. A browse takes
/// a snapshot of them when it begins, so a message that arrives meanwhile does
/// not shift the place.
///
/// Rules:
/// - The first Up saves the draft and shows the newest entry; each further Up
///   an older one (it stops at the oldest).
/// - Down shows a newer entry; Down from the newest gives the draft back.
/// - An edit to a shown entry ends the browse: the edited text is the draft.
/// - A send ends the browse.
struct ComposerHistory: Equatable {
    /// Which way a step goes.
    enum Direction: Equatable { case older, newer }

    /// The snapshot of entries taken when the browse began, newest first.
    private(set) var snapshot: [String] = []
    /// The shown entry's index in ``snapshot``; nil when the box shows the draft.
    private(set) var index: Int?
    /// The draft the person had typed when the browse began.
    private(set) var savedDraft = ""

    /// Whether the box shows an entry now (not the draft).
    var isBrowsing: Bool { index != nil }

    /// The entry the box shows now, nil when it shows the draft.
    var shown: String? { index.flatMap { snapshot[checked: $0] } }

    /// One step. `current` is the box's text now; `entries` the history now
    /// (read only when a browse begins). Returns the text the box should show,
    /// nil when the step changes nothing (no history, past the oldest, Down
    /// with no browse).
    mutating func step(_ direction: Direction, current: String, entries: @autoclosure () -> [String]) -> String? {
        switch direction {
        case .older:
            guard let i = index else {
                let all = entries()
                guard let newest = all.first else { return nil }
                snapshot = all
                savedDraft = current
                index = 0
                return newest
            }
            guard i + 1 < snapshot.count else { return nil }
            index = i + 1
            return snapshot[checked: i + 1]
        case .newer:
            guard let i = index else { return nil }
            if i == 0 {
                let draft = savedDraft
                end()
                return draft
            }
            index = i - 1
            return snapshot[checked: i - 1]
        }
    }

    /// The box's text changed. A change away from the shown entry (the person
    /// edited it) ends the browse; a step's own change keeps it.
    mutating func textChanged(to text: String) {
        guard let shown, shown != text else { return }
        end()
    }

    /// Ends the browse (a send, an edit): the box's text is the draft again.
    mutating func end() {
        snapshot = []
        index = nil
        savedDraft = ""
    }

    /// The person's sent messages in `state`'s loaded transcript, newest
    /// first: each one's text as shown now (an edit's `Edit.text` is the text
    /// before that edit, so it is not read); deleted, retracted
    /// and text-less messages skipped, and a repeat of the entry just newer
    /// than it dropped (as a shell's `ignoredups`).
    static func entries(in state: AppState) -> [String] {
        let me = state.me
        var out: [String] = []
        for m in state.conversation.messages.reversed() where m.senderId == me && m.deletedAt == nil && m.retractedAt == nil {
            let text = m.parts.compactMap(\.plainText).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, out.last != text else { continue }
            out.append(text)
        }
        return out
    }
}
