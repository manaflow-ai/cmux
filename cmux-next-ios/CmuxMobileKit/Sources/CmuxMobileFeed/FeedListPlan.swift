import CmuxAgentQuestion
import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

/// A Feed row's own UI state: what the person did to this row on this
/// screen, which changes its layout (the event itself lives in the store).
struct FeedRowState: Hashable, Sendable {
    /// Show more: the body's cap lifted.
    var expanded = false
    /// The quote bubble shows all its lines.
    var quoteExpanded = false
    /// The inline reply composer is open, with this draft.
    var replying = false
    var replyDraft = ""
    /// A reply that could not be sent, or the chat's refusal, shown under the replies.
    var replyFailure: String?
    /// Copy was tapped (the footer's checkmark for a moment).
    var copied = false
    /// The code card's "Show all N lines" was tapped.
    var codeExpanded = false
    /// A pending question's card state (page, selections, Other text) while it is answered.
    var question: AgentQuestionCardState?
    /// A body only the web renderer draws (math): its measured height at this width.
    var webHeight: Double?
    /// The row is a stack's fold line ("3 earlier updates"), not an event (`FeedStacks`).
    var fold: FeedFold?
}

/// A stack's fold line: how many older events of the chat it stands for, and whether they show under it.
struct FeedFold: Hashable, Sendable {
    var count: Int
    var expanded: Bool

    /// "3 earlier updates".
    var title: String { count == 1 ? "1 earlier update" : "\(count) earlier updates" }
}

/// The Feed's rows with each chat's run folded. When one chat (one Mac's workspace and tab) posts several
/// events in a row, with no other chat's event between them, the newest shows as the full row and
/// the older ones fold into one line under it; a tap on the line shows them in place (the iOS
/// Notification Center's stack per thread). One busy agent takes one row and a line, so the other
/// agents stay on screen. A row that needs the person is never folded and never leads a stack, nor
/// is one with an answer on its way or a refused answer; a row with an open reply is never folded.
struct FeedStacks: Equatable {
    /// The rows the list shows, in order: events, and after each stack's newest event its fold line
    /// (an event that carries only the fold's id and its chat), then its older events when expanded.
    var rows: [FeedItem] = []
    /// Each fold line, by its row id.
    var folds: [String: FeedFold] = [:]
    /// The newest event of each stack (its row and its fold line read as one).
    var heads: Set<String> = []
    /// The events folded away, in order.
    var hidden: [String] = []

    static let foldPrefix = "feed.fold."
    static func foldID(head: String) -> String { foldPrefix + head }
    static func isFold(_ id: String) -> Bool { id.hasPrefix(foldPrefix) }
    /// The newest event of the stack whose fold line is `id`.
    static func head(ofFold id: String) -> String? { isFold(id) ? String(id.dropFirst(foldPrefix.count)) : nil }

    /// Whether an event may be part of a stack.
    static func stacks(_ item: FeedItem) -> Bool {
        !item.needsYou && item.pending == nil && item.error == nil
    }

    /// `expanded`: the stacks shown open, by their newest event's id. A stack that gets a newer
    /// event stays open (its key moves to the new newest event), and keys of stacks that are gone
    /// are dropped. `open`: rows that never fold (a reply being written under them); one may still lead a stack.
    #if os(iOS)
    /// The rules are in Rust (`feed_stacking`, cmux-mobile-link-ffi); this maps the events in and the rows out.
    init(_ items: [FeedItem], expanded: inout Set<String>, open: Set<String> = []) {
        let plan = feedStacking(
            items: items.map {
                FeedStackItem(id: $0.id, macId: $0.macID, workspaceId: $0.workspaceID, tabId: $0.tabID, keepsOwnRow: !Self.stacks($0))
            },
            expanded: Array(expanded), open: Array(open)
        )
        rows.reserveCapacity(plan.rows.count)
        for row in plan.rows {
            switch row {
            case .event(let index):
                rows.append(items[Int(index)])
            case .fold(let index, let count, let isExpanded):
                let head = items[Int(index)]
                let foldID = Self.foldID(head: head.id)
                folds[foldID] = FeedFold(count: Int(count), expanded: isExpanded)
                rows.append(FeedItem(id: foldID, kind: .response, workspaceID: head.workspaceID, tabID: head.tabID, agentName: head.agentName,
                                     harness: "", workspaceTitle: "", markdown: "", quote: nil, createdAt: .distantPast))
            }
        }
        heads = Set(plan.heads)
        hidden = plan.hidden
        let live = Set(plan.expanded)
        if expanded != live { expanded = live }
    }
    #endif
}

/// What a row's layout depends on: the event, the row's state, the column
/// width and the text size. Equal keys always give equal layouts.
struct FeedRowKey: Hashable, Sendable {
    var item: FeedItem
    var state: FeedRowState
    var width: Int
    var textSize: String
}

/// One layout per row, kept until its key changes: a live change to one
/// event lays out that event's row again and no other (the SwiftUI Feed
/// built and measured every row that scrolled in, every time).
@MainActor
final class FeedRowLayoutCache<Value> {
    private var entries: [String: (key: FeedRowKey, value: Value)] = [:]

    var count: Int { entries.count }

    func cached(_ key: FeedRowKey) -> Value? {
        guard let entry = entries[key.item.id], entry.key == key else { return nil }
        return entry.value
    }

    func store(_ value: Value, for key: FeedRowKey) {
        entries[key.item.id] = (key, value)
    }

    func value(for key: FeedRowKey, compute: () -> Value) -> Value {
        if let hit = cached(key) { return hit }
        let value = compute()
        store(value, for: key)
        return value
    }

    /// Forgets rows no longer in the list.
    func prune(keeping ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    func removeAll() { entries = [:] }
}

/// How one store update reaches the list: whether the order changed (a
/// snapshot), which shown rows must be reconfigured (their key changed), and
/// which rows are new.
struct FeedListPlan: Equatable {
    var orderChanged: Bool
    /// Rows already shown whose layout key changed, in the new order.
    var reconfigure: [String]
    /// Rows not shown before, in the new order.
    var inserted: [String]

    /// `unchanged`: rows whose key is known to be the one shown (not compared again).
    init(old: [(String, FeedRowKey)], new: [(String, FeedRowKey)], anchorID: String?, unchanged: Set<String> = []) {
        let before = Dictionary(old, uniquingKeysWith: { first, _ in first })
        self.init(oldOrder: old.map(\.0), shown: before, new: new, unchanged: unchanged)
    }

    /// The same plan from the shown order and keys as the list keeps them (no dictionary built per update).
    init(oldOrder: [String], shown: [String: FeedRowKey], new: [(String, FeedRowKey)], unchanged: Set<String>) {
        orderChanged = oldOrder.count != new.count || !zip(oldOrder, new).allSatisfy { $0 == $1.0 }
        var reconfigure: [String] = [], inserted: [String] = []
        for (id, key) in new {
            if unchanged.contains(id) { continue }
            if let previous = shown[id] {
                if previous != key { reconfigure.append(id) }
            } else {
                inserted.append(id)
            }
        }
        self.reconfigure = reconfigure
        self.inserted = inserted
    }

    var isEmpty: Bool { !orderChanged && reconfigure.isEmpty }

    /// The ids in `inserted` never seen before, recording them as seen.
    static func fresh(_ inserted: [String], seen: inout Set<String>) -> Set<String> {
        var fresh = Set<String>()
        for id in inserted where seen.insert(id).inserted { fresh.insert(id) }
        return fresh
    }

    /// New rows placed above `anchor` (the first row the person sees): the "N new" pill's count.
    func insertedAbove(anchor: String, in order: [String]) -> Int {
        guard let index = order.firstIndex(of: anchor) else { return 0 }
        let new = Set(inserted)
        return order[..<index].count { new.contains($0) }
    }
}

/// Inserts and removals that turn one row order into another, when the rows
/// both keep stay in the same order (a live event, a done swipe); nil when
/// they do not (a re-sort), so the list rebuilds the section instead.
struct FeedSnapshotEdit: Equatable {
    var removed: [String]
    /// New rows, each group inserted before a row that was already there.
    var groups: [Group]
    /// New rows after the last kept row.
    var tail: [String]

    struct Group: Equatable {
        var before: String
        var ids: [String]
    }

    #if os(iOS)
    /// The rules are in Rust (`feed_snapshot_edit`).
    init?(old: [String], new: [String]) {
        guard let edit = feedSnapshotEdit(old: old, new: new) else { return nil }
        removed = edit.removed
        groups = edit.groups.map { Group(before: $0.before, ids: $0.ids) }
        tail = edit.tail
    }
    #endif
}

/// The pinned group at the top of the whole Feed: the asks still waiting on the person, which
/// `FeedStore.pinningNeedsYou` puts before every other event. An ask that leaves the group (or
/// joins it again) moves its row, so the list follows it by eye.
enum FeedPinnedGroup {
    /// How many rows of `items` (in list order) are the pinned group. Only the whole Feed has
    /// one: a filtered Feed is a single list in time order, and its chip already names it.
    static func count(_ items: [FeedItem], filter: FeedFilter) -> Int {
        guard filter == .all else { return 0 }
        return items.prefix(while: \.needsYou).count
    }
}

/// One row order turned into another by moving a few rows (`movers`: an ask that was answered
/// leaves the pinned group for its place in time, one that opened again goes back), with
/// inserts and removals beside them; nil when any other row changes place too (a re-sort) or
/// too many move at once to follow by eye. The list applies the steps to its snapshot and
/// animates them, so the answered ask travels to its place instead of the list being rebuilt.
struct FeedMoveEdit: Equatable {
    enum Step: Equatable {
        /// Put a shown row before `before` (nil: after the last row).
        case move(String, before: String?)
        /// Put a new row before `before` (nil: after the last row).
        case insert(String, before: String?)
    }

    var removed: [String]
    /// From the last row to the first: each step's `before` row is already in its place.
    var steps: [Step]

    #if os(iOS)
    /// The rules are in Rust (`feed_move_edit`, `feed_move_edit_applied`).
    init?(old: [String], new: [String], movers: Set<String>, limit: Int = 4) {
        guard let edit = feedMoveEdit(old: old, new: new, movers: Array(movers), limit: UInt32(clamping: max(0, limit))) else { return nil }
        removed = edit.removed
        steps = edit.steps.map { $0.moved ? .move($0.id, before: $0.before) : .insert($0.id, before: $0.before) }
    }

    /// The steps applied to `old` (what the list does to its snapshot).
    func applied(to old: [String]) -> [String] {
        let plan = FeedMovePlan(
            removed: removed,
            steps: steps.map {
                switch $0 {
                case .move(let id, let before): FeedMoveStep(id: id, before: before, moved: true)
                case .insert(let id, let before): FeedMoveStep(id: id, before: before, moved: false)
                }
            }
        )
        return feedMoveEditApplied(edit: plan, old: old)
    }
    #endif
}
