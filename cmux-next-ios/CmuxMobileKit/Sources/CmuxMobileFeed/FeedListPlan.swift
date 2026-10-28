import CmuxAgentQuestion
import Foundation

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

    init?(old: [String], new: [String]) {
        let newSet = Set(new), oldSet = Set(old)
        guard old.filter(newSet.contains) == new.filter(oldSet.contains) else { return nil }
        removed = old.filter { !newSet.contains($0) }
        groups = []
        var buffer: [String] = []
        for id in new {
            if oldSet.contains(id) {
                if !buffer.isEmpty { groups.append(Group(before: id, ids: buffer)); buffer = [] }
            } else {
                buffer.append(id)
            }
        }
        tail = buffer
    }
}
