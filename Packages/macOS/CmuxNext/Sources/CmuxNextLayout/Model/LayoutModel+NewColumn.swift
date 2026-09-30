public import CmuxNextDesign

// New columns: width from cmux.json `layout.defaultColumnWidth` (niri
// `default-column-width`), plus the lone full-width column rule
// (`NewColumnWidth.plan`, plans/cmux-next/niri.md "Column widths").
extension LayoutModel {
    /// Width of a new column as a viewport fraction: the override, else the
    /// live setting while `followsDesignMetrics` is on, else the built-in 0.5.
    public var defaultColumnWidth: Double {
        defaultColumnWidthOverride ?? (followsDesignMetrics ? DesignSettings.shared.defaultColumnWidth : ColumnWidthPreset.defaultWidth)
    }

    /// Call right before a new column opens next to `pane` by any path (new
    /// column action, a split with no room, a tab dropped into a new column).
    /// Returns the width to send with the new column and the lone column's
    /// width change. Nothing is sent: cmux-tui keeps a lone column as a leaf
    /// root with no viewport, so a width command before the new column
    /// exists is refused and the lone column stays full width. The caller
    /// sends the change with `commitNewColumnResize` once the new column
    /// exists. `removing` is a pane that leaves in the same step.
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
        let plan = NewColumnWidth.plan(columns: columns, width: defaultColumnWidth, removing: removing)
        let panes = plan.resize.flatMap { resize in columns.first { $0.id == resize.column } }?.root.panes.filter { $0 != removing } ?? []
        return NewColumnRequest(width: plan.width, resizeWidth: plan.resize?.width, resizePanes: panes)
    }

    /// After the new column exists: shrinks the lone column (a width intent
    /// with an optimistic patch). No-op when the request has no change or
    /// its panes are gone.
    public func commitNewColumnResize(_ request: NewColumnRequest) {
        guard let width = request.resizeWidth else { return }
        for pane in request.resizePanes {
            guard let layout = screen(containing: pane)?.layout else { continue }
            if let column = layout.column(containing: pane) {
                return setColumnWidth(column.id, width: width, transaction: .make(), phase: .ended)
            }
            // The mirror has not seen the new column yet (still a split
            // tree): send the width by pane; the column's id comes with the
            // daemon's next layout.
            return intentHandler?(.setColumnWidth(ColumnID(Self.unscrolledColumn), anyPane: pane, width: width,
                                                  transaction: .make(), phase: .ended)) ?? ()
        }
    }

    /// Stands for the one column of a screen whose root is still a split tree.
    static let unscrolledColumn = "unscrolled"

    /// Requests a new column after `pane`'s column (default: the focused
    /// pane), niri-style, at `defaultColumnWidth`.
    public func newColumn(after pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        intentHandler?(.newColumn(after: pane, width: prepareNewColumn(nextTo: pane).width))
    }
}

/// The width of a new column and the lone column's width change, which the
/// caller sends after the new column exists (`commitNewColumnResize`).
public nonisolated struct NewColumnRequest: Hashable, Sendable {
    public let width: Double
    let resizeWidth: Double?
    let resizePanes: [PaneID]
}
