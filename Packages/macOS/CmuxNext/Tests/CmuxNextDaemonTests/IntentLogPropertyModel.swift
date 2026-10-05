import Foundation
import Testing
@testable import CmuxNextDaemon

/// splitmix64: small, seedable, the same sequence on every machine.
struct IntentRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The owner's tab layout: panes in order, each with its tabs in order. A
/// pane of `panes` without an entry is closed.
struct RefLayout: Equatable, CustomStringConvertible {
    static let panes: [PaneID] = [4, 7, 21]
    var tabs: [PaneID: [SurfaceID]]

    var description: String { Self.panes.map { "\($0):\(tabs[$0].map { "\($0)" } ?? "closed")" }.joined(separator: " ") }
    var openPanes: [PaneID] { Self.panes.filter { tabs[$0] != nil } }
    var allTabs: [SurfaceID] { Self.panes.flatMap { tabs[$0] ?? [] } }

    func pane(of surface: SurfaceID) -> PaneID? { Self.panes.first { tabs[$0]?.contains(surface) == true } }

    /// cmux-tui `move-tab` with a final index; returns false when nothing
    /// moved (no event): the tab or the pane is missing, or the tab is at
    /// its place.
    mutating func move(_ surface: SurfaceID, to pane: PaneID, index: Int) -> Bool {
        guard tabs[pane] != nil, let source = self.pane(of: surface), let from = tabs[source]?.firstIndex(of: surface) else { return false }
        if source == pane {
            let final = min(max(index, 0), tabs[pane]!.count - 1)
            guard final != from else { return false }
            tabs[pane]!.remove(at: from)
            tabs[pane]!.insert(surface, at: final)
        } else {
            tabs[source]!.remove(at: from)
            tabs[pane]!.insert(surface, at: min(max(index, 0), tabs[pane]!.count))
        }
        return true
    }
}

struct RefTabMeta: Equatable {
    var name: String?
    var pinned = false
}

struct RefWorkspace: Equatable {
    var key: WorkspaceKey
    var handle: WorkspaceHandle
    var name: String
    var group: WorkspaceGroupID?
}

/// Everything an intent can change, as the owner holds it: the tab
/// layout, each placed tab's name and pin, the workspace order with names
/// and groups, and workspace and tab group collapse. The reference
/// semantics below are cmux-tui's, written independently of the store.
struct RefState: Equatable, CustomStringConvertible {
    static let groups: [WorkspaceGroupID] = ["g1", "g2"]
    static let tabGroup: TabGroupID = "tg"
    /// Workspace 1 of the fixture: holds the panes under test.
    static let main: WorkspaceKey = "c7a12f08-d868-42cd-9f98-a2ca1f6d9eb1"

    var layout: RefLayout
    /// One entry per tab in `layout`.
    var meta: [SurfaceID: RefTabMeta]
    var workspaces: [RefWorkspace]
    var groupCollapsed: [WorkspaceGroupID: Bool]
    var tabGroupCollapsed: Bool

    var description: String {
        let tabs = layout.allTabs.map { surface in
            let meta = meta[surface] ?? RefTabMeta()
            return "\(surface)\(meta.name.map { "=\($0)" } ?? "")\(meta.pinned ? "*" : "")"
        }
        let order = workspaces.map { "\($0.name)\($0.group.map { "@\($0.rawValue)" } ?? "")" }
        let folded = Self.groups.filter { groupCollapsed[$0] == true }.map(\.rawValue)
        return "\(layout) tabs[\(tabs.joined(separator: ","))] ws[\(order.joined(separator: ","))] folded\(folded) tg=\(tabGroupCollapsed)"
    }

    func index(of key: WorkspaceKey) -> Int? { workspaces.firstIndex { $0.key == key } }

    /// Applies `intent` with the owner's semantics; returns whether
    /// anything changed. A missing tab changes nothing (the owner rejects
    /// it; the overlay skips it).
    mutating func apply(_ intent: Intent) -> Bool {
        switch intent {
        case .moveTab(let surface, let pane, let index):
            return layout.move(surface, to: pane, index: index)
        case .renameTab(let surface, let name):
            guard meta[surface] != nil, meta[surface]?.name != name else { return false }
            meta[surface]?.name = name
            return true
        case .setTabPinned(let surface, let pinned):
            guard meta[surface] != nil, meta[surface]?.pinned != pinned else { return false }
            meta[surface]?.pinned = pinned
            return true
        case .renameWorkspace(let key, let name):
            guard let at = index(of: key), workspaces[at].name != name else { return false }
            workspaces[at].name = name
            return true
        case .moveWorkspace(let key, let index):
            guard let from = self.index(of: key) else { return false }
            return place(from: from, to: min(max(index, 0), workspaces.count - 1), group: workspaces[from].group)
        case .setWorkspaceGroup(let key, let group):
            guard let from = index(of: key) else { return false }
            return place(from: from, to: from, group: group)
        case .placeWorkspace(let key, let group, let index):
            guard let old = self.index(of: key) else { return false }
            // presentation.rs move_workspace_to_group.
            let remaining = workspaces.indices.filter { $0 != old }
            let members = remaining.filter { workspaces[$0].group == group }
            var new = old
            if let last = members.last {
                let target = index < members.count ? members[index] : last
                new = (remaining.firstIndex(of: target) ?? old) + (index < members.count ? 0 : 1)
            }
            return place(from: old, to: min(new, workspaces.count - 1), group: group)
        case .setWorkspaceGroupCollapsed(let id, let collapsed):
            guard groupCollapsed[id] != collapsed else { return false }
            groupCollapsed[id] = collapsed
            return true
        case .setTabGroupCollapsed(_, let collapsed):
            guard tabGroupCollapsed != collapsed else { return false }
            tabGroupCollapsed = collapsed
            return true
        case .setRowHeights:
            // The property world has no rows.
            return false
        case .createTab:
            // The property world creates no tabs (IntentCreateTabTests covers creation).
            return false
        }
    }

    private mutating func place(from: Int, to: Int, group: WorkspaceGroupID?) -> Bool {
        guard from != to || workspaces[from].group != group else { return false }
        var moved = workspaces.remove(at: from)
        moved.group = group
        workspaces.insert(moved, at: to)
        return true
    }

    /// Whether the owner can run `intent` (its tab is placed).
    func accepts(_ intent: Intent) -> Bool {
        switch intent {
        case .moveTab(let surface, let pane, _): layout.pane(of: surface) != nil && layout.tabs[pane] != nil
        case .renameTab(let surface, _), .setTabPinned(let surface, _): meta[surface] != nil
        default: true
        }
    }
}

struct IntentPropertyFailure: Error {}

/// Counts settlements per transaction (the store's `onIntentSettled`).
@MainActor final class IntentSettleLog {
    private var counts: [ClientTransactionID: Int] = [:]
    func record(_ transaction: ClientTransactionID) { counts[transaction, default: 0] += 1 }
    func count(_ transaction: ClientTransactionID) -> Int { counts[transaction] ?? 0 }
}
