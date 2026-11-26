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
        /// How `layout` differs from the screen's tree, for the screen's index.
        let change: LayoutIndex.Change
        let paneAt: Int
    }

    /// A screen's new tree and columns.
    struct Shown {
        let layout: LayoutNode
        let columns: [ColumnSnapshot]
        /// False when `columns` are the screen's as they were (the patch edited none).
        let columnsEdited: Bool
        /// How `layout` differs from the screen's tree, for the screen's index.
        var change: LayoutIndex.Change = .other
    }

    /// A split of `target` showing `leaf` (New Column with `column`, New Row with `row`, wrapping split `around` whole,
    /// `leaf` first when `before`); nil when it shows nothing: cmux-tui would refuse it, or the screen's tree already
    /// places `leaf`.
    static func split(_ screen: ScreenModel, target: PaneID, direction: SplitDirection, ratio: Double, leaf: PaneID,
                      splitID: String, column: ProvisionalColumn?, row: ProvisionalRow?, around: SplitID?, before: Bool,
                      targetPane: PaneModel? = nil) -> Placed? {
        let layout = screen.layout, columns = screen.columns
        // A plain split looks for the split `around` when it wraps one; New Column and New Row always the target's leaf.
        let wraps = column == nil && row == nil ? around : nil
        // The screen keeps its tree's index, so the lookups below cost the target's depth, not the screen.
        let index = screen.layoutIndex()
        let spots = findSpots(layout, columns, holding: target, match: wraps.map(Match.split) ?? .leaf(target), index: index)
        // Each kind sends only the facts its rule reads, so no walk runs that no rule needs.
        let panes = screen.panes
        var facts = Facts(leafPlaced: index?.contains(pane: leaf) ?? layout.contains(pane: leaf), columns: columns.count,
                          panes: panes.count)
        if column == nil {
            // The target's model's slot, by identity: no observed `handle` read per pane.
            facts.targetIndex = targetPane.flatMap(screen.slot(of:)) ?? panes.firstIndex { $0.handle == target }
        }
        if column != nil || row != nil {
            facts.zoomed = screen.zoomedPane != nil
            facts.inScreen = index?.contains(pane: target) ?? layout.contains(pane: target)
            facts.column = spots.first { $0.column != nil }?.column
        }
        if column != nil {
            if columns.isEmpty, let index {
                facts.span = span(ofScreen: index, panes)
            } else {
                let tree = columns.isEmpty ? layout : facts.column.flatMap { columns[checked: $0]?.layout }
                facts.span = tree.flatMap { span(of: $0, in: screen) }
            }
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
        return Placed(layout: shown.layout, columns: shown.columns, columnsEdited: shown.columnsEdited, change: shown.change,
                      paneAt: patch.paneAt ?? panes.count)
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
        let spots = findSpots(layout, columns, holding: pane, match: .holding(pane), index: screen.layoutIndex())
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
    /// `index` (the screen's ``LayoutIndex``) finds the screen tree's node without the walk.
    private static func findSpots(_ layout: LayoutNode, _ columns: [ColumnSnapshot], holding pane: PaneID, match: Match,
                                  index: LayoutIndex?) -> [Spot] {
        func spot(_ tree: LayoutNode, column: Int?, row: Int?) -> Spot {
            var path: [Bool] = []
            let node = tree.find(match, path: &path)
            return Spot(column: column, row: row, path: node == nil ? [] : path, node: node)
        }
        var spots = [index.map { indexedSpot(layout, $0, match: match) } ?? spot(layout, column: nil, row: nil)]
        for (c, column) in columns.enumerated() where column.layout.contains(pane: pane) {
            spots.append(spot(column.layout, column: c, row: nil))
            for (r, row) in column.rows.enumerated() where row.layout.contains(pane: pane) {
                spots.append(spot(row.layout, column: c, row: r))
            }
        }
        return spots
    }

    /// ``LayoutNode/find(_:path:)`` of `match` in the screen's tree, read from its exact index: the first node in the
    /// walk's order that matches is the only one, so the indexed place is it, or no node matches.
    private static func indexedSpot(_ layout: LayoutNode, _ index: LayoutIndex, match: Match) -> Spot {
        let path: [Bool]? = switch match {
        case .leaf(let pane), .holding(let pane): index.path(of: pane)
        case .split(let handle): index.path(of: handle)
        }
        guard let path, let node = layout.node(at: ArraySlice(path)), match.matches(node) else {
            return Spot(column: nil, row: nil, path: [], node: nil)
        }
        return Spot(column: nil, row: nil, path: path, node: node)
    }

    /// ``span(of:in:)`` of the screen's whole tree from its index: the scan stops at the first and last listed pane
    /// the tree shows, the ends of the list when it shows them all.
    private static func span(ofScreen index: LayoutIndex, _ panes: [PaneModel]) -> [Int]? {
        guard let first = panes.firstIndex(where: { index.contains(pane: $0.handle) }),
              let last = panes.lastIndex(where: { index.contains(pane: $0.handle) }) else { return nil }
        return [first, last]
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
        var change = LayoutIndex.Change.unchanged
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
                    // One node replaced in place is an index edit; a removal (its parent collapses) or a second edit is not.
                    if case .unchanged = change, let new { change = .splice(path: spot.path, old: held, new: new) } else { change = .other }
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
            change = .other
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
        return Shown(layout: layout, columns: columns, columnsEdited: columnsEdited, change: change)
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
