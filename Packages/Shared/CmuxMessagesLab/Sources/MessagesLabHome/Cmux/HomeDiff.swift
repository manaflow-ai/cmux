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
///   another client, Chief or the CLI: MessagesLab's external insert); a
///   thread reply carries its root as `replyTo` (HomeMapping.replyTo), so it
///   arrives as MessagesLab's thread reply
/// - a send this view started is already in the projection (`aliases`): its
///   echo only updates the status
/// - status (delivered, read, not delivered): `.status`, the newest change only
/// - tapbacks: `.react` per participant and part (the reducer toggles); mine
///   with no author, MessagesLab's own tapback (its badge pops, Springs.tapback)
/// - retracted: `.unsend`; edited (editedAt moved): `.edit`
/// - typing: `.typing` on and off
/// - anything MessagesLab has no action for (a removed message, content that
///   changed in place, a bulk refetch): `rebuild`, the whole window without
///   animation, keeping the scroll position.
/// - a new message that sorts before a row the projection already shows (the
///   owner committed it before my pending send, or a posted reply that is not
///   the newest row): the reducer only appends, so this is a `rebuild` in the
///   store's order (plans/cmux-next/home-chat-pipeline-DESIGN.md, B1 and B2).
///   The projection never shows an order the store does not have.
struct HomeDiff: Equatable {
    var actions: [Action] = []
    var rebuild = false
    /// Where the running replies' posted messages go among `actions` (their streams'
    /// `.streamEnd(replacedBy:)` are dispatched there, in transcript order).
    var handOffAt: Int?

    static func == (a: HomeDiff, b: HomeDiff) -> Bool {
        a.rebuild == b.rebuild && a.actions.map(describe) == b.actions.map(describe)
    }

    /// More new messages than this at once is a refetch (a reconnect, a gap):
    /// no per-message transitions.
    static let bulk = 3

    static func plan(old: [TranscriptItem], new: [TranscriptItem], oldSummary: ConversationSummary?,
                     newSummary: ConversationSummary?, aliases: [IdempotencyKey: ID], me: ParticipantID,
                     media: @escaping HomeMapping.Media = { _ in nil }, links: @escaping HomeMapping.Links = { _ in nil },
                     handOff: Set<IdempotencyKey> = []) -> HomeDiff {
        var d = HomeDiff()
        let oldIndex = Dictionary(old.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newKeys = Set(new.map(\.key))
        if old.contains(where: { !newKeys.contains($0.key) }) { d.rebuild = true; return d }
        func id(_ i: TranscriptItem) -> ID { HomeMapping.id(i, aliases: aliases) }
        let roots = HomeMapping.roots(in: new, aliases: aliases, summary: newSummary, media: media, links: links)
        let oldRoots = HomeMapping.roots(in: old, aliases: aliases, summary: oldSummary, media: media, links: links)
        func msg(_ i: TranscriptItem) -> Message { HomeMapping.message(i, aliases: aliases, me: me, summary: newSummary, media: media, links: links, roots: roots) }

        // Older page: the new messages before the first shown one.
        var head = 0
        if let first = old.first, let k = new.firstIndex(where: { $0.key == first.key }) { head = k }
        let page = new.prefix(head).filter { oldIndex[$0.key] == nil && aliases[$0.key] == nil }
        if !page.isEmpty { d.actions.append(.prependPage(page.map(msg))) }

        let added = new.dropFirst(head).filter { oldIndex[$0.key] == nil && aliases[$0.key] == nil }
        if added.count > bulk { d.rebuild = true; return d }
        // The order the projection will have after these actions: the page, the rows it shows, my
        // sends flying in it (appended at the press), then each `.receive` appended in turn, with the
        // posted replies of running streams all where the first of them is (`handOffAt`). Any other
        // order than the store's is a rebuild.
        if !orderHolds(old: old, new: new, head: head, aliases: aliases, handOff: handOff) { d.rebuild = true; return d }

        for item in new.dropFirst(head) { // // crash program: no range subscripts
            if let oi = oldIndex[item.key], let was = old[checked: oi] {
                // A shown reply whose thread or parent changed (its root or parent paged in or out, or was retracted): MessagesLab has no action for it.
                guard HomeMapping.replyTo(was, roots: oldRoots) == HomeMapping.replyTo(item, roots: roots),
                      HomeMapping.parent(was, roots: oldRoots) == HomeMapping.parent(item, roots: roots) else { d.rebuild = true; return d }
                guard changes(from: was, to: item, oldSummary: oldSummary, newSummary: newSummary, me: me, id: id(item),
                              parts: { msg($0).parts }, into: &d) else {
                    d.rebuild = true; return d
                }
            } else if aliases[item.key] != nil {
                // My send, already flying in the projection (status .sending).
                let st = HomeMapping.status(item, me: me, summary: newSummary)
                if let st, st != .sending { d.actions.append(.status(id(item), st)) }
                // Reply to Selection: the flying bubble has the quote's text; the stored reply adds its style.
                if item.parts.contains(where: { if case let .text(t, _) = $0 { return ReplyQuote.split(t) != nil } else { return false } }) {
                    d.actions.append(.cmuxSetParts(id(item), msg(item).parts))
                }
                if !item.reactions.isEmpty { react(from: [], to: item.reactions, id: id(item), owners: owners(item, newSummary), me: me, into: &d) }
            } else if !handOff.contains(item.key) {
                d.actions.append(.receive(msg(item)))
            } else if d.handOffAt == nil {
                d.handOffAt = d.actions.count // the running replies' streams take them in place (ProjectionCore.streams)
            }
        }
        d.keepNewestStatus()
        return d
    }

    /// True when appending the new rows (`.receive`, the streams' hand-offs) leaves the projection in `new`'s order.
    private static func orderHolds(old: [TranscriptItem], new: [TranscriptItem], head: Int,
                                   aliases: [IdempotencyKey: ID], handOff: Set<IdempotencyKey>) -> Bool {
        let shownKeys = Set(old.map(\.key))
        var projected = new.prefix(head).filter { !shownKeys.contains($0.key) && aliases[$0.key] == nil }.map(\.key)
        projected += old.map(\.key)
        // My sends that fly in the projection but were not in the last snapshot: after it, in the order I made them.
        projected += new.filter { !shownKeys.contains($0.key) && aliases[$0.key] != nil }.map(\.key)
        var handOffs: [IdempotencyKey] = []
        var appended: [IdempotencyKey] = []
        var handOffAt: Int?
        for item in new.dropFirst(head) where !shownKeys.contains(item.key) && aliases[item.key] == nil {
            if handOff.contains(item.key) {
                if handOffAt == nil { handOffAt = appended.count }
                handOffs.append(item.key)
            } else {
                appended.append(item.key)
            }
        }
        if let handOffAt { appended.insert(contentsOf: handOffs, at: handOffAt) }
        projected += appended
        return projected == new.map(\.key)
    }

    /// One read cursor moves every older message of mine to read at once;
    /// MessagesLab shows a receipt only under the newest read or delivered
    /// message (RowBuilder.receiptTargets) and its engine sends one status per
    /// change, so only the newest status change is a transition. The older
    /// ones change nothing visible (a rebuild maps every status).
    private mutating func keepNewestStatus() {
        let statuses = actions.enumerated().filter { if case .status = $0.element { true } else { false } }.map(\.offset) // // crash program: no index math
        for i in statuses.dropLast().reversed() { actions.remove(at: i) }
    }

    /// Actions for one shown message; false when MessagesLab cannot express it.
    /// A message with a Chief card (cmux issue 25830) that changed (the Chief edits its browser card at
    /// each step) takes its new parts in place, without "Edited": `.cmuxSetParts` when it shows as
    /// many parts as before, else a rebuild.
    private static func changes(from o: TranscriptItem, to n: TranscriptItem, oldSummary: ConversationSummary?,
                                newSummary: ConversationSummary?, me: ParticipantID, id: ID, parts: (TranscriptItem) -> [Part],
                                into d: inout HomeDiff) -> Bool {
        if !o.isRetracted, n.isRetracted { d.actions.append(.unsend(id)); return true }
        let card = { (item: TranscriptItem) in item.parts.contains { if case .card = $0 { return true } else { return false } } }
        if o.parts != n.parts, !n.isRetracted, card(o) || card(n) {
            guard owners(o, oldSummary).count == owners(n, newSummary).count else { return false }
            d.actions.append(.cmuxSetParts(id, parts(n)))
        } else {
            guard edited(from: o, to: n, oldSummary: oldSummary, newSummary: newSummary, id: id, into: &d) else { return false }
        }
        let s0 = HomeMapping.status(o, me: me, summary: oldSummary), s1 = HomeMapping.status(n, me: me, summary: newSummary)
        if let s1, s1 != s0 { d.actions.append(.status(id, s1)) }
        if o.reactions != n.reactions { react(from: o.reactions, to: n.reactions, id: id, owners: owners(n, newSummary), me: me, into: &d) }
        return true
    }

    /// A text edit as MessagesLab's `.edit`; false when the content changed in a way it cannot express.
    private static func edited(from o: TranscriptItem, to n: TranscriptItem, oldSummary: ConversationSummary?,
                               newSummary: ConversationSummary?, id: ID, into d: inout HomeDiff) -> Bool {
        // MessagesLab's `.edit` replaces one text bubble: a text that shows as
        // several (Messages' link rule) before or after the edit is a rebuild.
        let split = owners(o, oldSummary).count != o.parts.count || owners(n, newSummary).count != n.parts.count
        if o.editedAt != n.editedAt, !n.isRetracted, !split, let text = n.parts.compactMap({ if case .text(let t, _) = $0 { t } else { nil } }).first {
            d.actions.append(.edit(id, text))
        } else if o.parts != n.parts {
            return false
        }
        return true
    }

    /// One tapback per participant and part: the reducer replaces a changed
    /// one and toggles a removed one off. Mine has no author (`by: nil`), as
    /// MessagesLab dispatches the user's own tapback: the reducer's actor is
    /// then `me` all the same, and the window view pops its badge and times it
    /// as a tapback (from the menu's input when chosen there, PaneTapback.swift).
    /// Which HomeStore part each MessagesLab part shows (`HomeMapping.projectedParts`).
    private static func owners(_ item: TranscriptItem, _ summary: ConversationSummary?) -> [Int] {
        HomeMapping.projectedParts(item, summary: summary).owners
    }

    private static func react(from old: [CmuxHomeCore.Reaction], to new: [CmuxHomeCore.Reaction], id: ID, owners: [Int],
                              me: ParticipantID, into d: inout HomeDiff) {
        struct Slot: Hashable { var author: ParticipantID; var part: Int }
        let before = Dictionary(old.map { (Slot(author: $0.author, part: $0.partIndex), $0.kind) }, uniquingKeysWith: { _, b in b })
        let after = Dictionary(new.map { (Slot(author: $0.author, part: $0.partIndex), $0.kind) }, uniquingKeysWith: { _, b in b })
        for slot in Set(before.keys).union(after.keys).sorted(by: { ($0.author.rawValue, $0.part) < ($1.author.rawValue, $1.part) }) {
            let a = before.value(for: slot), b = after.value(for: slot) // // crash program: dictionary reads
            guard a != b else { continue }
            let ref = PartRef(messageId: id, partIndex: HomeMapping.projectedIndex(slot.part, owners))
            let by = slot.author == me ? nil : slot.author.rawValue
            if let b { d.actions.append(.react(ref, HomeMapping.kind(b), by: by)) }
            else if let a { d.actions.append(.react(ref, HomeMapping.kind(a), by: by)) }
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
