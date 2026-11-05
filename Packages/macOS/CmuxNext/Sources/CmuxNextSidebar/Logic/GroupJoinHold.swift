import CmuxNextWakeups
import Foundation
public import Observation

/// A new workspace that joins a named group (`acpmux new --group`, `cmux agent open --group`) lists once, in that
/// group. Its join is a sidebar-document move the app sends only once the daemon lists the workspace, and the
/// daemon's create puts it with the loose rows: the sidebar drew it there for a frame or more, then moved it into its
/// group (Leo, 2026-11-03: "it's just weird how it flickers into some top level group or whatever then goes away").
/// While a held workspace lists outside every group, the sidebar leaves its row out; it shows from the pass that
/// lists it in a group. A join that never lands cannot hide a workspace: once it has listed loose for `limit`, it
/// shows where it lists.
public struct GroupJoinHold: Sendable, Equatable {
    /// How long a held workspace may list loose before it shows there anyway: a sidebar-document move lands well
    /// within it.
    public static let limit: Duration = .seconds(2)

    /// Each held workspace, with when it first listed loose (nil: not listed loose yet; its create may be slow).
    private var held: [String: ContinuousClock.Instant?] = [:]

    public init() {}

    public var isEmpty: Bool { held.isEmpty }

    public func holds(_ id: String) -> Bool { held[id] != nil }

    /// Holds new workspace `id` until it lists in a group.
    public mutating func hold(_ id: String) { held[id] = .some(nil) }

    /// Its create ended without the workspace (or was taken back): nothing to hold.
    public mutating func release(_ id: String) { held[id] = nil }

    /// The held workspaces `sections` lists outside any group, to leave out of them in this pass. A held workspace
    /// listed in a group is released (its row draws there from its first frame), so is one that has listed loose for
    /// `limit`: the caller asks again once `limit` has passed while it leaves one out.
    public mutating func hiding(in sections: [SidebarSection], now: ContinuousClock.Instant) -> Set<String> {
        guard !held.isEmpty else { return [] }
        var hidden: Set<String> = []
        for section in sections {
            for node in section.nodes {
                switch node {
                case let .workspace(workspace):
                    let id = workspace.id.rawValue
                    guard let since = held[id] else { continue }
                    let first = since ?? now
                    if now - first >= Self.limit {
                        held[id] = nil
                    } else {
                        held[id] = .some(first)
                        hidden.insert(id)
                    }
                case let .group(group):
                    for workspace in group.workspaces { held[workspace.id.rawValue] = nil }
                case .item:
                    continue
                }
            }
        }
        return hidden
    }
}

/// The app's ``GroupJoinHold`` for its sidebar passes: what a pass leaves out, and one redraw at the hold's limit while
/// it leaves a row out (a one-shot deadline, set again only by a pass that still leaves one out), so a row whose join
/// never landed shows with no other change to wake the sidebar.
@MainActor @Observable
public final class GroupJoinRows {
    @ObservationIgnored private var state = GroupJoinHold()
    /// Bumped at the limit: the sidebar's tracked pass reads it, so it runs again.
    private var checks = 0
    @ObservationIgnored private let limit = DemandTimer(owner: "GroupJoinRows.limit")

    public init() {}

    public func hold(_ id: String) { state.hold(id) }
    public func release(_ id: String) { state.release(id) }

    /// The held workspaces `listed` shows loose, to leave out of this pass.
    public func hidden(in listed: [SidebarSection]) -> Set<String> {
        _ = checks
        guard !state.isEmpty else { return [] }
        let hidden = state.hiding(in: listed, now: .now)
        if !hidden.isEmpty { limit.scheduleIfIdle(after: GroupJoinHold.limit) { @MainActor [weak self] in self?.checks &+= 1 } }
        return hidden
    }
}
