import AppKit

/// Row hover state: the loaded-cell sweep, the pause while rows are off
/// screen or a drag runs, and the live Row Hover setting.
extension SidebarWorkspaceTableController {
    /// A hidden docked pane keeps applying content, so its reveal shows
    /// current rows, but its spinners, status pulses and hover pause.
    func setRowsOnScreen(_ onScreen: Bool) {
        guard rowsAreOnScreen != onScreen else { return }
        rowsAreOnScreen = onScreen
        if !onScreen { setHoveredRowId(nil) }
        let animates = isPresentationActive && onScreen
        containerView?.tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? SidebarWorkspaceRowTableCellView)?.setPresentationActive(animates)
            (rowView.view(atColumn: 0) as? SidebarGroupHeaderTableCellView)?.setPresentationActive(animates)
        }
    }

    /// True from the drag's first lift until its session ends.
    var isHoverSuspendedForDrag: Bool {
        isWorkspaceDragSourceActive || reorderLiftSession != nil
    }

    /// Clears hover on every loaded row before a drag shows its lift, so the
    /// lift snapshot never bakes a hover fill in and no row keeps one.
    func suspendHoverForDrag() {
        setHoveredRowId(nil)
        enforceHoverOnVisibleCells()
    }

    /// Re-derives hover from the live pointer once a drag has fully torn
    /// down (drop apply, lift end, settle glide), covering every loaded row.
    func rederiveHoverAfterDrag() {
        recomputeHoveredRow()
        enforceHoverOnVisibleCells()
    }

    /// Authoritative pass over every loaded cell so hover chrome (row fill,
    /// close button, header plus) cannot strand: per-transition repaints
    /// resolve ids against a rows array that can mutate in the same tick
    /// (content churn scrolling rows under a parked pointer), and a missed
    /// repaint left multiple rows showing hover chrome at once. Loaded, not
    /// just visible: prepared rows past the viewport scroll in without a
    /// reconfigure, and a row view animating out (row -1) must drop hover.
    func enforceHoverOnVisibleCells() {
        guard let table = containerView?.tableView else { return }
        table.enumerateAvailableRowViews { rowView, row in
            let rowId = rows.indices.contains(row) ? rows[row].id : nil
            let hovering = rowId != nil && hoveredRowId == rowId && contextMenuRowId != rowId
            switch rowView.view(atColumn: 0) {
            case let cell as SidebarGroupHeaderTableCellView:
                cell.enforcePointerHovering(hovering)
            case let cell as SidebarWorkspaceRowTableCellView:
                cell.enforcePointerHovering(hovering)
            default:
                break
            }
        }
    }

    /// Settings > Sidebar > Row Hover applies live: the sweep repaints every
    /// loaded row's wash (same-hover enforcement repaints it).
    func observeRowHoverSetting() {
        guard rowHoverObservation == nil else { return }
        rowHoverObservation = UserDefaults.standard.observe(\.sidebarRowHover, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.enforceHoverOnVisibleCells() }
        }
    }
}
