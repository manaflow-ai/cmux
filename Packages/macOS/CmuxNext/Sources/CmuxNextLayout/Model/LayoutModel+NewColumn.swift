public import CmuxNextDesign

// New columns: width from cmux.json `layout.newColumnWidth` (matchCurrent,
// fitScreen, or fixed at `layout.defaultColumnWidth` with the lone
// full-width column rule; plans/cmux-next/column-sizing.md, column-scroll.md).
extension LayoutModel {
    /// Width of a new column as a viewport fraction: the override, else the
    /// live setting while `followsDesignMetrics` is on, else the built-in 0.5.
    public var defaultColumnWidth: Double {
        defaultColumnWidthOverride ?? (followsDesignMetrics ? DesignSettings.shared.defaultColumnWidth : ColumnWidthPreset.defaultWidth)
    }

    /// `layout.newColumnWidth`: the override, else the live setting while
    /// `followsDesignMetrics` is on, else matchCurrent.
    public var newColumnWidthMode: NewColumnWidthMode {
        newColumnWidthModeOverride ?? (followsDesignMetrics ? DesignSettings.shared.newColumnWidth : .matchCurrent)
    }

    /// Call right before a new column opens next to `pane` by any path (new
    /// column action, a tab dropped into a new column). Returns the width to
    /// send with the new column and the width changes of existing columns
    /// (`layout.newColumnWidth`, plans/cmux-next/column-sizing.md). Nothing
    /// is sent: cmux-tui keeps a lone column as a leaf root with no
    /// viewport, so a width command before the new column exists is
    /// refused. The caller sends the changes with `commitNewColumnResize`
    /// once the new column exists. `removing` is a pane that leaves in the
    /// same step.
    public func prepareNewColumn(nextTo pane: PaneID, removing: PaneID? = nil) -> NewColumnRequest {
        let layout = screen(containing: pane)?.layout
        // A screen that has never had a second column is a split tree (the
        // daemon root is not a viewport yet): it fills the view like a lone
        // full-width column.
        let columns: [LayoutColumn] = switch layout {
        case .splits(let root)?: [LayoutColumn(id: ColumnID(Self.unscrolledColumn), width: 1, root: root)]
        case .columns(let columns)?: columns
        case nil: []
        }
        let anchor = columns.first { $0.root.contains(pane) }?.id
        let visible = columns.filter { $0.root.panes.contains(where: visiblePanes.contains) }.map(\.id)
        let plan = NewColumnWidth.plan(mode: newColumnWidthMode, columns: columns, anchor: anchor, visible: visible,
                                       fixedWidth: defaultColumnWidth, removing: removing)
        let resizes = plan.resizes.compactMap { resize -> NewColumnRequest.Resize? in
            let panes = columns.first { $0.id == resize.column }?.root.panes.filter { $0 != removing } ?? []
            return panes.isEmpty ? nil : NewColumnRequest.Resize(width: resize.width, panes: panes)
        }
        return NewColumnRequest(width: plan.width, resizes: resizes)
    }

    /// After the new column exists: sends each width change (a width
    /// intent with an optimistic patch). No-op for a change whose panes
    /// are gone.
    public func commitNewColumnResize(_ request: NewColumnRequest) {
        for resize in request.resizes {
            for pane in resize.panes {
                guard let layout = screen(containing: pane)?.layout else { continue }
                if let column = layout.column(containing: pane) {
                    setColumnWidth(column.id, width: resize.width, transaction: .make(), phase: .ended)
                } else {
                    // The mirror has not seen the new column yet (still a
                    // split tree): send the width by pane; the column's id
                    // comes with the daemon's next layout.
                    intentHandler?(.setColumnWidth(ColumnID(Self.unscrolledColumn), anyPane: pane, width: resize.width,
                                                   transaction: .make(), phase: .ended))
                }
                break
            }
        }
    }

    /// Stands for the one column of a screen whose root is still a split tree.
    static let unscrolledColumn = "unscrolled"

    /// Requests a new column after `pane`'s column (default: the focused
    /// pane), at the `layout.newColumnWidth` width.
    public func newColumn(after pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        intentHandler?(.newColumn(after: pane, width: prepareNewColumn(nextTo: pane).width))
    }
}

/// The width of a new column and the width changes of existing columns,
/// which the caller sends after the new column exists (`commitNewColumnResize`).
public nonisolated struct NewColumnRequest: Hashable, Sendable {
    struct Resize: Hashable, Sendable {
        let width: Double
        /// The column's panes; the first still shown addresses the command.
        let panes: [PaneID]
    }

    public let width: Double
    let resizes: [Resize]
}
