import CmuxHomeCore
import Foundation

/// The MessagesLab actions that take the projection store from one HomeStore
/// snapshot to the next (plans step 2: the catalyst reducer is kept only as a
/// projection of HomeStore plus this view's pending sends). Pure: the
/// adapter dispatches the result through the vendored ChatController, so
/// every change is one MessagesLab transaction with MessagesLab's springs.
///
/// - older messages before the first shown one: `.prependPage`
/// - a new message: `.receive` (theirs: the receive transition; mine from
///   another client, Chief or the CLI: MessagesLab's external insert)
/// - a send this view started is already in the projection (`aliases`): its
///   echo only updates the status
/// - status (delivered, read, not delivered): `.status`
/// - tapbacks: `.react` per participant and part (the reducer toggles)
/// - retracted: `.unsend`; edited (editedAt moved): `.edit`
/// - typing: `.typing` on and off
/// - anything MessagesLab has no action for (a removed message, content that
///   changed in place, a bulk refetch): `rebuild`, the whole window without
///   animation, keeping the scroll position.
struct HomeDiff: Equatable {
    var actions: [Action] = []
    var rebuild = false

    static func == (a: HomeDiff, b: HomeDiff) -> Bool {
        a.rebuild == b.rebuild && a.actions.map(describe) == b.actions.map(describe)
    }

    /// More new messages than this at once is a refetch (a reconnect, a gap):
    /// no per-message transitions.
    static let bulk = 3

    static func plan(old: [TranscriptItem], new: [TranscriptItem], oldSummary: ConversationSummary?,
                     newSummary: ConversationSummary?, aliases: [IdempotencyKey: ID], me: ParticipantID) -> HomeDiff {
        var d = HomeDiff()
        let oldIndex = Dictionary(old.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newKeys = Set(new.map(\.key))
        if old.contains(where: { !newKeys.contains($0.key) }) { d.rebuild = true; return d }
        func id(_ i: TranscriptItem) -> ID { HomeMapping.id(i, aliases: aliases) }
        func msg(_ i: TranscriptItem) -> Message { HomeMapping.message(i, aliases: aliases, me: me, summary: newSummary) }

        // Older page: the new messages before the first shown one.
        var head = 0
        if let first = old.first, let k = new.firstIndex(where: { $0.key == first.key }) { head = k }
        let page = new[..<head].filter { oldIndex[$0.key] == nil && aliases[$0.key] == nil }
        if !page.isEmpty { d.actions.append(.prependPage(page.map(msg))) }

        let added = new[head...].filter { oldIndex[$0.key] == nil && aliases[$0.key] == nil }
        if added.count > bulk { d.rebuild = true; return d }

        for item in new[head...] {
            if let oi = oldIndex[item.key] {
                guard changes(from: old[oi], to: item, oldSummary: oldSummary, newSummary: newSummary, me: me, id: id(item), into: &d) else {
                    d.rebuild = true; return d
                }
            } else if aliases[item.key] != nil {
                // My send, already flying in the projection (status .sending).
                let st = HomeMapping.status(item, me: me, summary: newSummary)
                if let st, st != .sending { d.actions.append(.status(id(item), st)) }
                if !item.reactions.isEmpty { react(from: [], to: item.reactions, id: id(item), into: &d) }
            } else {
                d.actions.append(.receive(msg(item)))
            }
        }
        return d
    }

    /// Actions for one shown message; false when MessagesLab cannot express it.
    private static func changes(from o: TranscriptItem, to n: TranscriptItem, oldSummary: ConversationSummary?,
                                newSummary: ConversationSummary?, me: ParticipantID, id: ID, into d: inout HomeDiff) -> Bool {
        if !o.isRetracted, n.isRetracted { d.actions.append(.unsend(id)); return true }
        if o.editedAt != n.editedAt, !n.isRetracted, let text = n.parts.compactMap({ if case .text(let t, _) = $0 { t } else { nil } }).first {
            d.actions.append(.edit(id, text))
        } else if o.parts != n.parts {
            return false
        }
        let s0 = HomeMapping.status(o, me: me, summary: oldSummary), s1 = HomeMapping.status(n, me: me, summary: newSummary)
        if let s1, s1 != s0 { d.actions.append(.status(id, s1)) }
        if o.reactions != n.reactions { react(from: o.reactions, to: n.reactions, id: id, into: &d) }
        return true
    }

    /// One tapback per participant and part: the reducer replaces a changed
    /// one and toggles a removed one off.
    private static func react(from old: [CmuxHomeCore.Reaction], to new: [CmuxHomeCore.Reaction], id: ID, into d: inout HomeDiff) {
        struct Slot: Hashable { var author: ParticipantID; var part: Int }
        let before = Dictionary(old.map { (Slot(author: $0.author, part: $0.partIndex), $0.kind) }, uniquingKeysWith: { _, b in b })
        let after = Dictionary(new.map { (Slot(author: $0.author, part: $0.partIndex), $0.kind) }, uniquingKeysWith: { _, b in b })
        for slot in Set(before.keys).union(after.keys).sorted(by: { ($0.author.rawValue, $0.part) < ($1.author.rawValue, $1.part) }) {
            let a = before[slot], b = after[slot]
            guard a != b else { continue }
            let ref = PartRef(messageId: id, partIndex: slot.part)
            if let b { d.actions.append(.react(ref, HomeMapping.kind(b), by: slot.author.rawValue)) }
            else if let a { d.actions.append(.react(ref, HomeMapping.kind(a), by: slot.author.rawValue)) }
        }
    }

    /// Typing changes against the projection's current typists (after the
    /// actions above: a received message already ended its sender's typing).
    static func typing(current: [ID], wanted: Set<ParticipantID>, me: ParticipantID) -> [Action] {
        let want = Set(wanted.filter { $0 != me }.map(\.rawValue))
        let have = Set(current)
        return have.subtracting(want).sorted().map { .typing($0, false) } + want.subtracting(have).sorted().map { .typing($0, true) }
    }

    /// A stable description for tests and equality.
    static func describe(_ a: Action) -> String {
        switch a {
        case let .receive(m): return "receive \(m.id) \(m.senderId)"
        case let .status(id, s): return "status \(id) \(s)"
        case let .prependPage(p): return "prepend \(p.map(\.id))"
        case let .typing(who, on): return "typing \(who) \(on)"
        case let .react(ref, kind, by): return "react \(ref.messageId):\(ref.partIndex) \(kind) \(by ?? "-")"
        case let .unsend(id): return "unsend \(id)"
        case let .edit(id, text): return "edit \(id) \(text)"
        default: return "\(a)"
        }
    }
}
