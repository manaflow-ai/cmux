import CCmuxLayoutReducerFFI
import Foundation

/// The store's optimistic overlay rules, answered by cmux-layout-reducer (`optimistic.rs`, operation
/// `optimistic` of `cmux_layout_reducer_json` in the app FFI): where a pending split, New Column, New Row or
/// dock shows, what a hidden pane leaves behind, where a moved tab or workspace lands and which row heights a
/// divider release writes. The overlay (``IntentOverlay``, ``ProvisionalSplit``, ``ProvisionalDock``,
/// ``CancelledCreation``) reads the records, asks here, and writes the answer into them: model identity and
/// every record write stay Swift. One call per intent apply or overlay restore, never per frame.
@MainActor enum OptimisticRules {
    /// A split's, New Column's or New Row's view: the screen's new tree and columns, and the index in the
    /// screen's panes where the provisional pane goes (used only when the records lack the daemon's pane).
    struct Placed: Decodable {
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
        let paneAt: Int

        enum CodingKeys: String, CodingKey {
            case layout, columns
            case paneAt = "pane_at"
        }
    }

    /// A screen's new tree and columns.
    struct Shown: Decodable {
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
    }

    /// A split of `target` showing `leaf` (New Column with `column`, New Row with `row`); nil when it shows
    /// nothing: cmux-tui would refuse it, or the screen's tree already places `leaf`.
    static func split(_ screen: ScreenModel, target: PaneID, direction: SplitDirection, ratio: Double, leaf: PaneID,
                      splitID: String, column: ProvisionalColumn?, row: ProvisionalRow?) -> Placed? {
        call(SplitRequest(screen: WireScreen(screen), target: target, dir: direction, ratio: ratio, leaf: leaf, splitID: splitID,
                          column: column.map { WireColumnSpec(handle: $0.handle.rawValue, width: $0.width, left: $0.left) },
                          row: row.map { WireRowSpec(handle: $0.handle.rawValue, height: $0.height) }))
    }

    /// A lone tab docked into a leading column holding `leaf`; nil while the daemon's layout must place it.
    static func dock(_ screen: ScreenModel, leaf: PaneID, column: ProvisionalColumn, dock: DockSnapshot) -> Shown? {
        call(DockRequest(screen: WireScreen(screen), leaf: leaf,
                         column: WireColumnSpec(handle: column.handle.rawValue, width: column.width, left: column.left),
                         dock: WireDock(dock)))
    }

    /// The screen without `pane`; nil when it must stay shown until its close.
    static func removePane(_ screen: ScreenModel, pane: PaneID) -> Shown? {
        call(RemovePaneRequest(screen: WireScreen(screen), pane: pane))
    }

    /// `move-tab`'s final index in a pane of `targetCount` tabs; nil when the tab is there already.
    static func moveTab(samePane: Bool, from: Int, index: Int, targetCount: Int) -> Int? {
        let answer: FinalIndex? = call(MoveTabRequest(samePane: samePane, from: from, index: index, targetCount: targetCount))
        return answer?.final
    }

    enum PlaceKind: String, Encodable {
        case move, group, place
    }

    /// The new daemon-order index of the workspace at `from` (`groups`: every workspace's group, in daemon
    /// order); nil when it stays where it is in the group it is in.
    static func placeWorkspace(groups: [WorkspaceGroupID?], from: Int, kind: PlaceKind, group: WorkspaceGroupID?, index: Int) -> Int? {
        struct Answer: Decodable { let index: Int }
        let answer: Answer? = call(PlaceWorkspaceRequest(groups: groups.map { $0?.rawValue }, from: from, kind: kind,
                                                         group: group?.rawValue, index: index))
        return answer?.index
    }

    /// The row heights `heights` writes on rows `rows`, in row order; nil when the row set differs
    /// (`row-set-stale`) or nothing changes.
    static func rowHeights(_ rows: [RowSnapshot], _ heights: [RowHeightValue]) -> [RowHeightValue]? {
        struct Answer: Decodable { let heights: [RowHeightValue] }
        let answer: Answer? = call(RowHeightsRequest(rows: rows.map { RowHeightValue(row: $0.id, height: $0.height) }, heights: heights))
        return answer?.heights
    }

    /// One tab a held close keeps out of the visible order, and its index before.
    struct HeldTab: Encodable {
        let surface: SurfaceID
        let index: Int
    }

    /// `move-tab`'s index in the daemon's order, and the tab's current one there, while the held closes (oldest
    /// first, each in removal order) keep tabs out of `visible`.
    static func daemonMoveIndex(visible: [SurfaceID], moving: SurfaceID, index: Int, held: [[HeldTab]]) -> (final: Int, current: Int?) {
        struct Answer: Decodable {
            let final: Int
            let current: Int?
        }
        guard let answer: Answer = call(DaemonMoveIndexRequest(visible: visible, moving: moving, index: index, held: held)) else {
            // Unreachable for a request this file encodes; the end of the pane is the move's safe place.
            return (visible.count, visible.firstIndex(of: moving))
        }
        return (answer.final, answer.current)
    }

    // MARK: The call

    private nonisolated static let initialCapacity = 4096

    /// Encodes `request`, runs it, and decodes the answer; nil for the rules' "shows nothing" (`null`) and for a
    /// call that failed (an encoding the operation refuses), which shows nothing either.
    private static func call<Request: Encodable, Answer: Decodable>(_ request: Request) -> Answer? {
        guard let data = try? JSONEncoder().encode(request), let answer = respond(data) else { return nil }
        return (try? JSONDecoder().decode(Answer?.self, from: answer)) ?? nil
    }

    /// One `optimistic` request's JSON answer (`null` when it shows nothing); nil when the operation refused it.
    nonisolated static func respond(_ request: Data) -> Data? {
        var capacity = initialCapacity
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { requestBytes in
                "optimistic".withCString { operation in
                    output.withUnsafeMutableBytes { outputBytes in
                        cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, request.count, operation,
                                                 outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity {
                capacity = length
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}

// MARK: Wire shapes (the daemon's: optimistic.rs reads the trees as the daemon sends them)
extension OptimisticRules {
    fileprivate struct FinalIndex: Decodable { let final: Int }

    fileprivate struct WireNode: Encodable {
        let node: LayoutNode

        enum CodingKeys: String, CodingKey {
            case type, pane, split, dir, ratio, a, b, panes, expanded
            case splitID = "split_id"
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch node {
            case .leaf(let pane):
                try c.encode("leaf", forKey: .type)
                try c.encode(pane, forKey: .pane)
            case .split(let id, let resourceID, let direction, let ratio, let a, let b):
                try c.encode("split", forKey: .type)
                try c.encodeIfPresent(id, forKey: .split)
                try c.encodeIfPresent(resourceID?.rawValue, forKey: .splitID)
                try c.encode(direction, forKey: .dir)
                try c.encode(ratio, forKey: .ratio)
                try c.encode(WireNode(node: a), forKey: .a)
                try c.encode(WireNode(node: b), forKey: .b)
            case .stack(let panes, let expanded):
                try c.encode("stack", forKey: .type)
                try c.encode(panes, forKey: .panes)
                try c.encode(expanded, forKey: .expanded)
            case .unknown:
                try c.encode("unknown", forKey: .type)
            }
        }
    }

    fileprivate struct WireDock: Encodable {
        let edge: String
        let mode: String
        let role: String?
        let pinned: Bool
        let allowTabs: Bool

        init(_ dock: DockSnapshot) {
            edge = dock.edge.rawValue
            mode = dock.mode.rawValue
            role = dock.role?.rawValue
            pinned = dock.isPinned
            allowTabs = dock.allowsTabs
        }

        enum CodingKeys: String, CodingKey {
            case edge, mode, role, pinned
            case allowTabs = "allow_tabs"
        }
    }

    fileprivate struct WireRow: Encodable {
        let id: RowID
        let height: Int
        let layout: WireNode
    }

    fileprivate struct WireColumn: Encodable {
        let id: ColumnID
        let width: Double
        let layout: WireNode
        let dock: WireDock?
        let rows: [WireRow]

        init(_ column: ColumnSnapshot) {
            id = column.id
            width = column.width
            layout = WireNode(node: column.layout)
            dock = column.dock.map(WireDock.init)
            rows = column.rows.map { WireRow(id: $0.id, height: $0.height, layout: WireNode(node: $0.layout)) }
        }
    }

    fileprivate struct WireScreen: Encodable {
        let layout: WireNode
        let columns: [WireColumn]
        let zoomedPane: PaneID?
        let panes: [PaneID]

        @MainActor init(_ screen: ScreenModel) {
            layout = WireNode(node: screen.layout)
            columns = screen.columns.map(WireColumn.init)
            zoomedPane = screen.zoomedPane
            panes = screen.panes.map(\.handle)
        }

        enum CodingKeys: String, CodingKey {
            case layout, columns, panes
            case zoomedPane = "zoomed_pane"
        }
    }

    fileprivate struct WireColumnSpec: Encodable {
        let handle: UInt64
        let width: Double
        let left: Bool
    }

    fileprivate struct WireRowSpec: Encodable {
        let handle: UInt64
        let height: Int
    }

    fileprivate struct SplitRequest: Encodable {
        let op = "split"
        let screen: WireScreen
        let target: PaneID
        let dir: SplitDirection
        let ratio: Double
        let leaf: PaneID
        let splitID: String
        let column: WireColumnSpec?
        let row: WireRowSpec?

        enum CodingKeys: String, CodingKey {
            case op, screen, target, dir, ratio, leaf, column, row
            case splitID = "split_id"
        }
    }

    fileprivate struct DockRequest: Encodable {
        let op = "dock"
        let screen: WireScreen
        let leaf: PaneID
        let column: WireColumnSpec
        let dock: WireDock
    }

    fileprivate struct RemovePaneRequest: Encodable {
        let op = "remove_pane"
        let screen: WireScreen
        let pane: PaneID
    }

    fileprivate struct MoveTabRequest: Encodable {
        let op = "move_tab"
        let samePane: Bool
        let from: Int
        let index: Int
        let targetCount: Int

        enum CodingKeys: String, CodingKey {
            case op, from, index
            case samePane = "same_pane"
            case targetCount = "target_count"
        }
    }

    fileprivate struct PlaceWorkspaceRequest: Encodable {
        let op = "place_workspace"
        let groups: [String?]
        let from: Int
        let kind: OptimisticRules.PlaceKind
        let group: String?
        let index: Int

        func encode(to encoder: any Encoder) throws {
            enum Keys: String, CodingKey { case op, groups, from, kind, group, index }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(op, forKey: .op)
            // Every slot is listed, an ungrouped one as null: the index is the daemon order's.
            var list = c.nestedUnkeyedContainer(forKey: .groups)
            for group in groups {
                if let group { try list.encode(group) } else { try list.encodeNil() }
            }
            try c.encode(from, forKey: .from)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(group, forKey: .group)
            try c.encode(index, forKey: .index)
        }
    }

    fileprivate struct RowHeightsRequest: Encodable {
        let op = "row_heights"
        let rows: [RowHeightValue]
        let heights: [RowHeightValue]

        func encode(to encoder: any Encoder) throws {
            enum Keys: String, CodingKey { case op, rows, heights }
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(op, forKey: .op)
            try c.encode(rows.map { WireRowNow(id: $0.row, height: $0.height) }, forKey: .rows)
            try c.encode(heights, forKey: .heights)
        }
    }

    fileprivate struct WireRowNow: Encodable {
        let id: RowID
        let height: Int
    }

    fileprivate struct DaemonMoveIndexRequest: Encodable {
        let op = "daemon_move_index"
        let visible: [SurfaceID]
        let moving: SurfaceID
        let index: Int
        let held: [[OptimisticRules.HeldTab]]
    }
}
