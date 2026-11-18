import CCmuxLayoutReducerFFI
import Foundation

/// The store's optimistic overlay rules, answered by cmux-layout-reducer (`optimistic.rs`, operation
/// `optimistic` of `cmux_layout_reducer_json` in the app FFI): where a pending split, New Column, New Row or
/// dock shows, what a hidden pane leaves behind, where a moved tab or workspace lands and which row heights a
/// divider release writes. The overlay (``IntentOverlay``, ``ProvisionalSplit``, ``ProvisionalDock``,
/// ``CancelledCreation``) reads the records, asks here, and writes the answer into them: model identity and
/// every record write stay Swift. One call per intent apply or overlay restore, never per frame.
///
/// A tree rule gets facts and the nodes it edits ("spots", found by a generic walk), never the whole screen,
/// and answers a small patch that `apply(_:layout:columns:spots:)` splices in, so untouched subtrees stay
/// shared and the cost does not grow with the layout. Refusal, placement, ids, widths and new nodes stay
/// Rust's; Swift only finds, reports and splices.
@MainActor enum OptimisticRules {
    /// A split's, New Column's or New Row's view: the screen's new tree and columns, and the index in the
    /// screen's panes where the provisional pane goes (used only when the records lack the daemon's pane).
    struct Placed {
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
        /// False when `columns` are the screen's as they were (the patch edited none).
        let columnsEdited: Bool
        let paneAt: Int
    }

    /// A screen's new tree and columns.
    struct Shown {
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
        /// False when `columns` are the screen's as they were (the patch edited none).
        let columnsEdited: Bool
    }

    /// A split of `target` showing `leaf` (New Column with `column`, New Row with `row`, wrapping split `around` whole,
    /// `leaf` first when `before`); nil when it shows nothing: cmux-tui would refuse it, or the screen's tree already
    /// places `leaf`.
    static func split(_ screen: ScreenModel, target: PaneID, direction: SplitDirection, ratio: Double, leaf: PaneID,
                      splitID: String, column: ProvisionalColumn?, row: ProvisionalRow?, around: SplitID?, before: Bool) -> Placed? {
        let layout = screen.layout, columns = screen.columns
        let spots = findSpots(layout, columns, holding: target, match: around.map(Match.split) ?? .leaf(target))
        // Each kind sends only the facts its rule reads, so no walk runs that no rule needs.
        var facts = Facts(leafPlaced: layout.contains(pane: leaf), columns: columns.count, panes: screen.panes.count)
        if column == nil {
            facts.targetIndex = screen.panes.firstIndex { $0.handle == target }
        }
        if column != nil || row != nil {
            facts.zoomed = screen.zoomedPane != nil
            facts.inScreen = layout.contains(pane: target)
            facts.column = spots.first { $0.column != nil }?.column
        }
        if column != nil {
            let tree = columns.isEmpty ? layout : facts.column.flatMap { columns[checked: $0]?.layout }
            facts.span = tree.flatMap { span(of: $0, in: screen) }
        }
        if row != nil, let index = facts.column, let held = columns[checked: index] {
            facts.rows = held.rows.count
            facts.row = spots.first { $0.column == index && $0.row != nil }?.row
        }
        let request = SplitRequest(target: target, dir: direction, ratio: ratio, leaf: leaf, splitID: splitID,
                                   column: column.map { WireColumnSpec(handle: $0.handle.rawValue, width: $0.width, left: $0.left) },
                                   row: row.map { WireRowSpec(handle: $0.handle.rawValue, height: $0.height) },
                                   around: around, before: before ? true : nil, facts: facts, spots: spots)
        guard let patch: Patch = call(request), let shown = apply(patch, layout: layout, columns: columns, spots: spots) else { return nil }
        return Placed(layout: shown.layout, columns: shown.columns, columnsEdited: shown.columnsEdited,
                      paneAt: patch.paneAt ?? screen.panes.count)
    }

    /// A lone tab docked into a leading column holding `leaf`; nil while the daemon's layout must place it.
    static func dock(_ screen: ScreenModel, leaf: PaneID, column: ProvisionalColumn, dock: DockSnapshot) -> Shown? {
        let layout = screen.layout, columns = screen.columns
        let facts = Facts(leafPlaced: layout.contains(pane: leaf), zoomed: screen.zoomedPane != nil, columns: columns.count,
                          dockEdges: columns.compactMap { $0.dock?.edge.rawValue })
        let request = DockRequest(leaf: leaf, column: WireColumnSpec(handle: column.handle.rawValue, width: column.width, left: column.left),
                                  dock: WireDock(dock), facts: facts)
        guard let patch: Patch = call(request) else { return nil }
        return apply(patch, layout: layout, columns: columns, spots: [])
    }

    /// The screen without `pane`; nil when it must stay shown until its close.
    static func removePane(_ screen: ScreenModel, pane: PaneID) -> Shown? {
        let layout = screen.layout, columns = screen.columns
        let spots = findSpots(layout, columns, holding: pane, match: .holding(pane))
        guard let patch: Patch = call(RemovePaneRequest(pane: pane, spots: spots)) else { return nil }
        return apply(patch, layout: layout, columns: columns, spots: spots)
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

    // MARK: Spots and facts

    /// The node `match` finds in the screen's tree, then in every column whose tree holds `pane`, and in each of
    /// that column's rows that holds it (the contract's spot order).
    private static func findSpots(_ layout: LayoutNode, _ columns: [ColumnSnapshot], holding pane: PaneID, match: Match) -> [Spot] {
        func spot(_ tree: LayoutNode, column: Int?, row: Int?) -> Spot {
            var path: [Bool] = []
            let node = tree.find(match, path: &path)
            return Spot(column: column, row: row, path: node == nil ? [] : path, node: node)
        }
        var spots = [spot(layout, column: nil, row: nil)]
        for (c, column) in columns.enumerated() where column.layout.contains(pane: pane) {
            spots.append(spot(column.layout, column: c, row: nil))
            for (r, row) in column.rows.enumerated() where row.layout.contains(pane: pane) {
                spots.append(spot(row.layout, column: c, row: r))
            }
        }
        return spots
    }

    /// The first and last index in the screen's panes of a pane `tree` holds; nil when it holds none of them.
    private static func span(of tree: LayoutNode, in screen: ScreenModel) -> [Int]? {
        var held = Set<PaneID>()
        tree.collectPanes(into: &held)
        let panes = screen.panes
        guard let first = panes.firstIndex(where: { held.contains($0.handle) }),
              let last = panes.lastIndex(where: { held.contains($0.handle) }) else { return nil }
        return [first, last]
    }

    // MARK: The splice

    /// The screen's tree and columns with `patch` spliced in: spot edits first (indexed by `spots`), then the
    /// whole tree, then column edits in order. Nil when the patch does not fit them (a stale or foreign answer),
    /// which shows nothing.
    private static func apply(_ patch: Patch, layout before: LayoutNode, columns original: [ColumnSnapshot], spots: [Spot]) -> Shown? {
        var layout = before, columns = original, columnsEdited = !patch.columns.isEmpty
        for edit in patch.spots {
            guard let spot = spots[checked: edit.spot], let held = spot.node else { return nil }
            var new: LayoutNode?
            if let part = edit.node {
                guard let node = part.node(held: held, screen: before, column: nil) else { return nil }
                new = node
            }
            let path = ArraySlice(spot.path)
            var spliced = false
            switch (spot.column, spot.row) {
            case (nil, _):
                if let tree = layout.splicing(at: path, with: new) {
                    layout = tree
                    spliced = true
                }
            case (let c?, nil):
                columns.modify(checked: c) { column in
                    guard let tree = column.layout.splicing(at: path, with: new) else { return }
                    column.layout = tree
                    spliced = true
                }
            case (let c?, let r?):
                columns.modify(checked: c) { column in
                    column.rows.modify(checked: r) { row in
                        guard let tree = row.layout.splicing(at: path, with: new) else { return }
                        row.layout = tree
                        spliced = true
                    }
                }
            }
            guard spliced else { return nil }
            if spot.column != nil { columnsEdited = true }
        }
        if let part = patch.layout {
            guard let tree = part.node(held: nil, screen: before, column: nil) else { return nil }
            layout = tree
        }
        for edit in patch.columns {
            switch edit {
            case .insert(let at, let new):
                guard at >= 0, at <= columns.count, let column = new.column(screen: before) else { return nil }
                columns.insert(column, at: at)
            case .remove(let at):
                guard columns.indices.contains(at) else { return nil }
                columns.remove(at: at)
            case .change(let at, let part, let rowEdits):
                guard let old = columns[checked: at] else { return nil }
                var column = old
                if let part {
                    guard let tree = part.node(held: nil, screen: before, column: old) else { return nil }
                    column.layout = tree
                }
                for rowEdit in rowEdits {
                    switch rowEdit {
                    case .insert(let j, let new):
                        guard j >= 0, j <= column.rows.count,
                              let tree = new.layout.node(held: nil, screen: before, column: old) else { return nil }
                        column.rows.insert(RowSnapshot(id: new.id, height: new.height, layout: tree), at: j)
                    case .remove(let j):
                        guard column.rows.indices.contains(j) else { return nil }
                        column.rows.remove(at: j)
                    }
                }
                columns.modify(checked: at) { $0 = column }
            }
        }
        return Shown(layout: layout, columns: columns, columnsEdited: columnsEdited)
    }

    // MARK: The call

    /// Every tree answer is a constant-size patch, so this never retries; a larger answer still does, once.
    private nonisolated static let initialCapacity = 16 * 1024

    /// Encodes `request`, runs it, and decodes the answer; nil for the rules' "shows nothing" (`null`) and for a
    /// call that failed (an encoding the operation refuses), which shows nothing either.
    private static func call<Request: Encodable, Answer: Decodable>(_ request: Request) -> Answer? {
        guard let data = try? JSONEncoder().encode(request), let answer = respond(data) else { return nil }
        return (try? JSONDecoder().decode(Answer?.self, from: answer)) ?? nil
    }

    /// One `optimistic` request's JSON answer (`null` when it shows nothing); nil when the operation refused it.
    private nonisolated static func respond(_ request: Data) -> Data? {
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

// MARK: Generic tree walks (no rule here: find, contains, last pane, splice)

extension LayoutNode {
    /// Whether `pane` is one of this tree's panes. Walks without allocating, unlike ``paneIDs``.
    func contains(pane: PaneID) -> Bool {
        switch self {
        case .leaf(let leaf): leaf == pane
        case .split(_, _, _, _, let a, let b): a.contains(pane: pane) || b.contains(pane: pane)
        case .stack(let panes, _): panes.contains(pane)
        case .unknown: false
        }
    }

    /// The last pane: a split's second side's, a stack's expanded pane.
    var lastPane: PaneID? {
        switch self {
        case .leaf(let pane): pane
        case .split(_, _, _, _, _, let b): b.lastPane
        case .stack(_, let expanded): expanded
        case .unknown: nil
        }
    }

    /// Adds every pane of the tree to `panes`.
    func collectPanes(into panes: inout Set<PaneID>) {
        switch self {
        case .leaf(let pane): panes.insert(pane)
        case .split(_, _, _, _, let a, let b):
            a.collectPanes(into: &panes)
            b.collectPanes(into: &panes)
        case .stack(let stacked, _): panes.formUnion(stacked)
        case .unknown: break
        }
    }

    /// The first node, depth first, `a` before `b`, descending only through splits, that `match` matches;
    /// `path` ends as its steps from the root (`true` for `b`).
    fileprivate func find(_ match: OptimisticRules.Match, path: inout [Bool]) -> LayoutNode? {
        if match.matches(self) { return self }
        guard case .split(_, _, _, _, let a, let b) = self else { return nil }
        path.append(false)
        if let found = a.find(match, path: &path) { return found }
        path.removeLast()
        path.append(true)
        if let found = b.find(match, path: &path) { return found }
        path.removeLast()
        return nil
    }

    /// The tree with the node at `path` replaced by `new`, rebuilding only the path. A nil `new` takes the node
    /// out and its parent split becomes its other side, as it is; nil when that leaves no tree.
    func splicing(at path: ArraySlice<Bool>, with new: LayoutNode?) -> LayoutNode? {
        guard let step = path.first, case .split(let id, let resourceID, let direction, let ratio, let a, let b) = self else { return new }
        guard let child = (step ? b : a).splicing(at: path.dropFirst(), with: new) else { return step ? a : b }
        return .split(id: id, resourceID: resourceID, direction: direction, ratio: ratio, a: step ? a : child, b: step ? child : b)
    }
}

// MARK: Wire shapes (cmux-layout-reducer `optimistic`: facts and spots in, a patch out)
extension OptimisticRules {
    fileprivate struct FinalIndex: Decodable { let final: Int }

    /// What a spot's walk looks for.
    fileprivate enum Match {
        /// A leaf showing the pane.
        case leaf(PaneID)
        /// A split under that daemon handle.
        case split(SplitID)
        /// A leaf showing the pane, or a stack holding it.
        case holding(PaneID)

        func matches(_ node: LayoutNode) -> Bool {
            switch (self, node) {
            case (.leaf(let pane), .leaf(let leaf)), (.holding(let pane), .leaf(let leaf)): leaf == pane
            case (.split(let handle), .split(let id, _, _, _, _, _)): id == handle
            case (.holding(let pane), .stack(let panes, _)): panes.contains(pane)
            default: false
            }
        }
    }

    /// One tree's found node: the screen's (no `column`), a column's, or a column's row's.
    fileprivate struct Spot: Encodable {
        let column: Int?
        let row: Int?
        /// Steps from the tree's root to `node` (`true` for `b`).
        let path: [Bool]
        let node: LayoutNode?

        enum CodingKeys: String, CodingKey {
            case column, row, root, node, type, pane, split, panes, expanded
            case lastPane = "last_pane"
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(column, forKey: .column)
            try c.encodeIfPresent(row, forKey: .row)
            guard let node else { return try c.encodeNil(forKey: .node) }
            if path.isEmpty { try c.encode(true, forKey: .root) }
            var n = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .node)
            switch node {
            case .leaf(let pane):
                try n.encode("leaf", forKey: .type)
                try n.encode(pane, forKey: .pane)
            case .split(let id, _, _, _, _, _):
                try n.encode("split", forKey: .type)
                try n.encodeIfPresent(id, forKey: .split)
                try n.encodeIfPresent(node.lastPane, forKey: .lastPane)
            case .stack(let panes, let expanded):
                try n.encode("stack", forKey: .type)
                try n.encode(panes, forKey: .panes)
                try n.encode(expanded, forKey: .expanded)
            case .unknown:
                try n.encode("unknown", forKey: .type)
            }
        }
    }

    /// What a rule reads of the screen; a field left nil is not sent (the rule's default).
    fileprivate struct Facts: Encodable {
        var leafPlaced: Bool?
        var zoomed: Bool?
        var columns: Int?
        var panes: Int?
        var targetIndex: Int?
        var inScreen: Bool?
        var column: Int?
        var span: [Int]?
        var rows: Int?
        var row: Int?
        var dockEdges: [String]?

        enum CodingKeys: String, CodingKey {
            case zoomed, columns, panes, column, span, rows, row
            case leafPlaced = "leaf_placed"
            case targetIndex = "target_index"
            case inScreen = "in_screen"
            case dockEdges = "dock_edges"
        }
    }

    /// A rule's answer: edits to the request's spots, the screen's new tree, and column edits.
    fileprivate struct Patch: Decodable {
        let spots: [SpotEdit]
        let layout: Part?
        let columns: [ColumnEdit]
        let paneAt: Int?

        enum CodingKeys: String, CodingKey {
            case spots, layout, columns
            case paneAt = "pane_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spots = try c.decodeIfPresent([SpotEdit].self, forKey: .spots) ?? []
            layout = try c.decodeIfPresent(Part.self, forKey: .layout)
            columns = try c.decodeIfPresent([ColumnEdit].self, forKey: .columns) ?? []
            paneAt = try c.decodeIfPresent(Int.self, forKey: .paneAt)
        }
    }

    /// Spot `spot`'s node replaced by `node`; nil `node` takes it out (its parent split collapses).
    fileprivate struct SpotEdit: Decodable {
        let spot: Int
        let node: Part?
    }

    /// A node of a patch: a new one, or a reference to a tree as it was.
    fileprivate indirect enum Part: Decodable {
        case leaf(PaneID)
        /// A new split (no daemon handle), under public id `splitID`.
        case split(splitID: String?, direction: SplitDirection, ratio: Double, a: Part, b: Part)
        case stack(panes: [PaneID], expanded: PaneID)
        /// The spot's node as it was.
        case held
        /// The screen's tree before the patch.
        case screen
        /// The edited column's tree before this edit.
        case column
        /// The edited column's row's tree before this edit.
        case row(Int)

        enum CodingKeys: String, CodingKey {
            case type, pane, dir, ratio, a, b, panes, expanded, row
            case splitID = "split_id"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "leaf": self = .leaf(try c.decode(PaneID.self, forKey: .pane))
            case "split":
                self = .split(splitID: try c.decodeIfPresent(String.self, forKey: .splitID),
                              direction: try c.decode(SplitDirection.self, forKey: .dir), ratio: try c.decode(Double.self, forKey: .ratio),
                              a: try c.decode(Part.self, forKey: .a), b: try c.decode(Part.self, forKey: .b))
            case "stack":
                self = .stack(panes: try c.decode([PaneID].self, forKey: .panes), expanded: try c.decode(PaneID.self, forKey: .expanded))
            case "held": self = .held
            case "screen": self = .screen
            case "column": self = .column
            case "row": self = .row(try c.decode(Int.self, forKey: .row))
            default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown patch part")
            }
        }

        /// The tree this part names; nil when it names one that is not there (`held` outside a spot edit,
        /// `column` or `row` outside a column change).
        func node(held: LayoutNode?, screen: LayoutNode, column: ColumnSnapshot?) -> LayoutNode? {
            switch self {
            case .leaf(let pane): return .leaf(pane)
            case .split(let splitID, let direction, let ratio, let a, let b):
                guard let a = a.node(held: held, screen: screen, column: column),
                      let b = b.node(held: held, screen: screen, column: column) else { return nil }
                return .split(id: nil, resourceID: splitID.map(ResourceID.init(rawValue:)), direction: direction, ratio: ratio, a: a, b: b)
            case .stack(let panes, let expanded): return .stack(panes: panes, expanded: expanded)
            case .held: return held
            case .screen: return screen
            case .column: return column?.layout
            case .row(let k):
                return column?.rows[checked: k]?.layout
            }
        }
    }

    fileprivate struct NewRow: Decodable {
        let id: RowID
        let height: Int
        let layout: Part
    }

    fileprivate struct NewColumn: Decodable {
        let id: ColumnID
        let width: Double
        let layout: Part
        let dock: DockSnapshot?
        let rows: [NewRow]

        enum CodingKeys: String, CodingKey { case id, width, layout, dock, rows }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(ColumnID.self, forKey: .id)
            width = try c.decode(Double.self, forKey: .width)
            layout = try c.decode(Part.self, forKey: .layout)
            dock = try c.decodeIfPresent(DockSnapshot.self, forKey: .dock)
            rows = try c.decodeIfPresent([NewRow].self, forKey: .rows) ?? []
        }

        func column(screen: LayoutNode) -> ColumnSnapshot? {
            guard let tree = layout.node(held: nil, screen: screen, column: nil) else { return nil }
            var rows: [RowSnapshot] = []
            for row in self.rows {
                guard let layout = row.layout.node(held: nil, screen: screen, column: nil) else { return nil }
                rows.append(RowSnapshot(id: row.id, height: row.height, layout: layout))
            }
            return ColumnSnapshot(id: id, width: width, layout: tree, dock: dock, rows: rows)
        }
    }

    fileprivate enum ColumnEdit: Decodable {
        case insert(at: Int, NewColumn)
        case remove(at: Int)
        /// `layout` replaces the column's tree; `rows` edits apply in order.
        case change(at: Int, layout: Part?, rows: [RowEdit])

        enum CodingKeys: String, CodingKey { case edit, at, layout, rows }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let at = try c.decode(Int.self, forKey: .at)
            switch try c.decode(String.self, forKey: .edit) {
            case "insert": self = .insert(at: at, try NewColumn(from: decoder))
            case "remove": self = .remove(at: at)
            case "change":
                self = .change(at: at, layout: try c.decodeIfPresent(Part.self, forKey: .layout),
                               rows: try c.decodeIfPresent([RowEdit].self, forKey: .rows) ?? [])
            default: throw DecodingError.dataCorruptedError(forKey: .edit, in: c, debugDescription: "unknown column edit")
            }
        }
    }

    fileprivate enum RowEdit: Decodable {
        case insert(at: Int, NewRow)
        case remove(at: Int)

        enum CodingKeys: String, CodingKey { case edit, at }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let at = try c.decode(Int.self, forKey: .at)
            switch try c.decode(String.self, forKey: .edit) {
            case "insert": self = .insert(at: at, try NewRow(from: decoder))
            case "remove": self = .remove(at: at)
            default: throw DecodingError.dataCorruptedError(forKey: .edit, in: c, debugDescription: "unknown row edit")
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
        let target: PaneID
        let dir: SplitDirection
        let ratio: Double
        let leaf: PaneID
        let splitID: String
        let column: WireColumnSpec?
        let row: WireRowSpec?
        let around: SplitID?
        let before: Bool?
        let facts: Facts
        let spots: [Spot]

        enum CodingKeys: String, CodingKey {
            case op, target, dir, ratio, leaf, column, row, around, before, facts, spots
            case splitID = "split_id"
        }
    }

    fileprivate struct DockRequest: Encodable {
        let op = "dock"
        let leaf: PaneID
        let column: WireColumnSpec
        let dock: WireDock
        let facts: Facts
    }

    fileprivate struct RemovePaneRequest: Encodable {
        let op = "remove_pane"
        let pane: PaneID
        let spots: [Spot]
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
}
