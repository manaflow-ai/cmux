import AppKit
import CmuxNextDesign

/// A resize of the screen (a window live-resize event, full screen, the sidebar's width): new rects, not a
/// new layout.
extension ScreenContentView {
    /// A resize of a screen at rest, as Chromium's `views::View::SetBoundsRect` then `Layout()` does it
    /// (ui/views/view.cc): the geometry at the new size and frames set only where a rect changed
    /// (``applyPresentation(force:)`` compares each), with no reconcile: no host, divider or container is
    /// made, moved or restyled, and nothing is taken back from the render server. Returns false, having
    /// done nothing, when the resize needs the reconcile: something moves or is held
    /// (``isAtRestForResize``), the backing scale changed, or the new geometry has other parts (a row
    /// column starts to overflow, a divider comes or goes).
    func resizeInPlace() -> Bool { // perf-hot: 4ms window-live-resize
        guard isAtRestForResize, reconciledScale == scale else { return false }
        let style = context.style
        let shown = rowDragPreview.map { layout.settingRowHeights($0.heights, for: $0.column) } ?? layout
        let resized = ScreenGeometry.compute(shown, viewport: bounds.size, style: style, scale: scale)
        let targets = dividerTargets(in: resized)
        guard resized.keepsParts(of: baseGeometry), Set(resized.panes.keys) == Set(paneFrames.keys),
              Set(targets.keys) == Set(dividerViews.keys) else { return false }
        resizesInPlace += 1
        let docksBefore = baseGeometry.dock
        motionTurn {
            applyCamera()
            baseGeometry = resized
            geometry = baseGeometry.shiftingAreas(areaOffsets).shiftingRows(rowOffsets)
            // A release seeds only the layout it made, and a resize is not one.
            releasedDivider = nil
            for (pane, target) in resized.panes {
                guard var frame = paneFrames[pane], frame.targetRect != target else { continue }
                place(&frame, at: target, animated: false)
                paneFrames[pane] = frame
            }
            for (kind, target) in targets {
                guard var frame = dividerFrames[kind], frame.targetRect != target.rect else { continue }
                place(&frame, at: target.rect, animated: false)
                dividerFrames[kind] = frame
            }
            for (entry, before) in zip(resized.dock, docksBefore) where entry != before && entry.dock.mode == .overlay {
                backdrops[entry.column]?.place(cover: entry.glass, column: entry.frame, paneCornerRadius: style.paneCornerRadius)
            }
            applyPresentation()
            return syncScroll(focused: lastFocused, source: .programmatic, mode: context.model.centerFocusedColumn, animated: false)
        }
        return true
    }

    /// Nothing moves, is held or is carried on this screen, and it shows the daemon layout (a canvas's
    /// camera is its bounds): a resize changes only rects (``resizeInPlace()``).
    var isAtRestForResize: Bool {
        !needsReconcileOnShow && !isCanvas && !hasMotion && !reportScrollOnSettle && !leadsFrame
            && activeDrag == nil && !isGesturing && !panFlingsInFlight
            && renderSpringsInFlight == 0 && renderClose == nil && renderTracks.isEmpty
            && zoomMotion.pane == nil && covered.isEmpty && arriving.isEmpty && newDockColumns.isEmpty
            && carriedShown.isEmpty && carriedDividers.isEmpty
    }

    /// The handle of every divider and column edge of `geometry`, and of its row edges where the daemon
    /// serves rows-v1 (only there are row heights resizable): its hit rect and axis.
    func dividerTargets(in geometry: ScreenGeometry) -> [DividerHandleView.Kind: (rect: CGRect, axis: SplitAxis)] {
        var targets: [DividerHandleView.Kind: (rect: CGRect, axis: SplitAxis)] = [:]
        for divider in geometry.dividers { targets[.split(divider.id)] = (divider.hitFrame, divider.axis) }
        for edge in geometry.columnEdges { targets[.columnEdge(edge.column)] = (edge.hitFrame, edge.axis) }
        if context.model.acceptsRowOps {
            for edge in geometry.rowEdges { targets[.rowEdge(edge.column, edge.upper)] = (edge.hitFrame, .vertical) }
        }
        return targets
    }
}

private extension ScreenGeometry {
    /// Whether this geometry (a resize of `other`) keeps every part the screen's views are built for: the
    /// strip or tree, where each pane sits (strip or dock, row column, scroll area), the docks, the row
    /// columns that overflow and the scroll areas. Panes and divider handles are compared by the caller.
    func keepsParts(of other: ScreenGeometry) -> Bool {
        isColumns == other.isColumns && frameOrientation == other.frameOrientation && columnOrder == other.columnOrder
            && fixedPanes == other.fixedPanes && fixedSplits == other.fixedSplits
            && dock.map(\.column) == other.dock.map(\.column) && dock.map(\.dock) == other.dock.map(\.dock)
            && rowStacks.mapValues(\.scrolls) == other.rowStacks.mapValues(\.scrolls)
            && rowColumnOfPane == other.rowColumnOfPane && scrollAreaOfPane == other.scrollAreaOfPane
            && Set(scrollAreas.keys) == Set(other.scrollAreas.keys)
    }
}
