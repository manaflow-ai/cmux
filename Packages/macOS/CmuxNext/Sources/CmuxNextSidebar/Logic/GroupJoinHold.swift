import Foundation
public import Observation

/// A new workspace that joins a named group (`acpmux new --group`, `cmux agent open --group`) lists once, in that
/// group. The daemon's create puts it with the loose rows, and its join is a sidebar-document move (Leo, 2026-11-03:
/// "it's just weird how it flickers into some top level group or whatever then goes away"). The join is written in
/// the pass that first lists the workspace: that pass leaves the row out and sends the move, which the document
/// applies at once (its optimistic look), so the next pass draws the row in its group. Nothing waits on a clock: a
/// joined workspace stays out only while the document has not shown its own change yet; once it has, a row still
/// listed loose (the move was refused) shows where it lists.
///
/// Leaned on: Nielsen's error prevention (https://www.nngroup.com/articles/ten-usability-heuristics/): the row is
/// placed in its group when it is first listed, instead of a timer hiding a second write.
public struct GroupJoinHold: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        /// The group name the workspace joins.
        var group: String
        /// Its join was sent (by this hold's pass, or by the create's placement first).
        var joined = false
    }

    private var held: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { held.isEmpty }

    public func holds(_ id: String) -> Bool { held[id] != nil }

    /// Holds new workspace `id` until it lists in group `group`.
    public mutating func hold(_ id: String, group: String) { held[id] = Entry(group: group) }

    /// Its create ended without the workspace (or was taken back): nothing to hold.
    public mutating func release(_ id: String) { held[id] = nil }

    /// Whether the caller should send `id`'s join now: true once per held workspace (and for one not held, which joins
    /// as before); false when its join was sent already.
    public mutating func claim(_ id: String) -> Bool {
        guard var entry = held[id] else { return true }
        if entry.joined { return false }
        entry.joined = true
        held[id] = entry
        return true
    }

    /// One pass over `sections`: the held workspaces to leave out of it, and the joins to send in it (workspace and
    /// group name; the caller claims each). A held workspace listed in a group is released (its row draws there from its
    /// first frame). One listed loose whose join is not sent yet is left out and its join is due. One listed loose after
    /// its join was sent stays out while `catchingUp` (the document applied a change it does not show yet); otherwise
    /// the move did not take, and it is released to show where it lists.
    public mutating func pass(over sections: [SidebarSection], catchingUp: Bool) -> (hidden: Set<String>, due: [(id: String, group: String)]) {
        guard !held.isEmpty else { return ([], []) }
        var hidden: Set<String> = []
        var due: [(id: String, group: String)] = []
        for section in sections {
            for node in section.nodes {
                switch node {
                case let .workspace(workspace):
                    let id = workspace.id.rawValue
                    guard let entry = held[id] else { continue }
                    if !entry.joined {
                        hidden.insert(id)
                        due.append((id, entry.group))
                    } else if catchingUp {
                        hidden.insert(id)
                    } else {
                        held[id] = nil
                    }
                case let .group(group):
                    for workspace in group.workspaces { held[workspace.id.rawValue] = nil }
                case .item:
                    continue
                }
            }
        }
        return (hidden, due)
    }
}

/// The app's ``GroupJoinHold`` for its sidebar passes: what a window's pass leaves out, and the joins that pass sends
/// once it has drawn (``takeDue(in:)``).
@MainActor @Observable
public final class GroupJoinRows {
    @ObservationIgnored private var state = GroupJoinHold()
    /// Per window: the joins its last pass found due, sent from that pass's apply.
    @ObservationIgnored private var due: [String: [(id: String, group: String)]] = [:]

    public init() {}

    public func hold(_ id: String, group: String) { state.hold(id, group: group) }
    public func release(_ id: String) { state.release(id) }
    /// See ``GroupJoinHold/claim(_:)``.
    public func claim(_ id: String) -> Bool { state.claim(id) }

    /// The held workspaces `listed` (window `window`'s pass) shows loose, to leave out of this pass. `catchingUp`: the
    /// sidebar document has applied a change its shown projection does not hold yet.
    public func hidden(in listed: [SidebarSection], window: String, catchingUp: Bool) -> Set<String> {
        guard !state.isEmpty else { return [] }
        let (hidden, found) = state.pass(over: listed, catchingUp: catchingUp)
        due[window] = found.isEmpty ? nil : found
        return hidden
    }

    /// The joins window `window`'s last pass found due, each claimed (so sent once, by this window or the placement).
    public func takeDue(in window: String) -> [(id: String, group: String)] {
        guard let found = due.removeValue(forKey: window) else { return [] }
        return found.filter { state.claim($0.id) }
    }
}
