import CmuxHomeCore
import Foundation

/// The agent's running reply on screen: MessagesLab's own received bubble,
/// aliased to the reply's key (`turn`), so the posted reply lands in it.
struct ShownDraft: Equatable {
    var turn: IdempotencyKey
    var author: ParticipantID
    var id: ID
    var text: String
    /// The bubble as it shows now (the draft's stable text rendered as a running reply).
    var shown: Message
}

/// What `ProjectionCore.draft` asks of the projection store.
struct DraftStep {
    var actions: [Action] = []
    /// The posted reply replaces its draft's text (final Markdown) in place.
    var rebuild = false
    var isEmpty: Bool { actions.isEmpty && !rebuild }
}

/// HomeStore.drafts through MessagesLab's bubble path (cx-k1uj): the first
/// text `.receive`s the agent's bubble (the typing dots turn into it), more
/// text updates it in place, the posted reply (same key) takes the
/// bubble's id and its final content, and a draft that ends without a reply
/// `.delete`s its bubble. A draft of an ended turn never reaches here
/// (HomeStore drops it), so a posted reply never gets its draft back.
extension ProjectionCore {
    /// The authors whose running reply shows (their typing dots stay off,
    /// also in the step that turns the dots into the bubble).
    func draftAuthors(_ want: HomeTurnDraft?) -> Set<ParticipantID> {
        guard let want, Self.visibleText(want) != nil else { return [] }
        return [want.participant]
    }

    /// True when `draft(_:state:)` would act.
    func draftDiffers(_ want: HomeTurnDraft?) -> Bool {
        let visible = want.flatMap { Self.visibleText($0) == nil ? nil : $0 }
        return visible?.turn != shownDraft?.turn || visible.map(\.text) != shownDraft.map(\.text)
    }

    /// cmux (round 8): the bubble shows the draft's stable text (`HomeMarkdown.stableStreamingText`: a
    /// trailing marker run or an unfinished link is held back until the next update), rendered as a
    /// running reply (an unclosed span on the last line is styled to its end). The bubble is never
    /// deleted and received again while the reply runs: words that only add text are appended in place
    /// (`.appendText`); a change of styling (a span that opens, closes or grows) or of text that does
    /// not extend what shows replaces the bubble's content in place, under the same id, through the
    /// projection's window replace (`rebuild`, which takes `shownDraft.shown`), so closed spans keep
    /// their style while the reply streams.
    mutating func draft(_ want: HomeTurnDraft?, state: AppState) -> DraftStep {
        var step = DraftStep()
        if let live = shownDraft, want?.turn != live.turn {
            shownDraft = nil
            if shown.contains(where: { $0.key == live.turn }) {
                step.rebuild = true
            } else {
                aliases[live.turn] = nil
                step.actions.append(.delete(live.id))
            }
        }
        // A reply already posted (a page brought it first) keeps its bubble until the draft ends.
        guard let want, let text = Self.visibleText(want), !shown.contains(where: { $0.key == want.turn }) else {
            return step
        }
        let stable = HomeMarkdown.stableStreamingText(text)
        guard !stable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return step }  // only a held-back marker so far
        if var live = shownDraft {
            guard text != live.text else { return step }
            live.text = text
            let next = bubble(want, text: stable)
            defer { live.shown = next; shownDraft = live }
            guard next.parts != live.shown.parts else { return step }
            if case let .text(old, oldRuns)? = Self.onlyText(live.shown), case let .text(new, newRuns)? = Self.onlyText(next),
               new.hasPrefix(old), newRuns == oldRuns {
                step.actions.append(.appendText(live.id, String(new.dropFirst(old.count))))
            } else {
                step.rebuild = true
            }
            return step
        }
        // An older window shows: the bubble comes with the posted reply at the newest.
        guard state.atNewest else { return step }
        let id = Self.bubbleID(want.turn, generation: 0)
        aliases[want.turn] = id
        let first = bubble(want, text: stable)
        shownDraft = ShownDraft(turn: want.turn, author: want.participant, id: id, text: text, shown: first)
        step.actions.append(.receive(first))
        return step
    }

    /// The bubble's one text part, nil when it shows as several parts (a link card) or none.
    private static func onlyText(_ m: Message) -> Part? {
        guard m.parts.count == 1, case .text? = m.parts.first else { return nil }
        return m.parts.first
    }

    /// The draft's text, nil while it is only whitespace.
    private static func visibleText(_ draft: HomeTurnDraft) -> String? {
        let text = draft.text
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func bubbleID(_ turn: IdempotencyKey, generation: Int) -> ID {
        "\(HomeMapping.rowSafe(turn.rawValue))~draft\(generation)"
    }

    /// The bubble the posted reply will be: the same mapping as a committed agent message.
    private func bubble(_ draft: HomeTurnDraft, text: String) -> Message {
        let item = TranscriptItem(key: draft.turn, seq: nil, author: draft.participant, parts: [.text(text)],
                                  createdAt: Date(), delivery: .committed)
        return HomeMapping.message(item, aliases: aliases, me: me, summary: summary, media: media, links: links, streaming: true)
    }

}
