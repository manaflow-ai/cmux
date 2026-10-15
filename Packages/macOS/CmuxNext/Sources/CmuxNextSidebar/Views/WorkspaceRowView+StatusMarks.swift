import AppKit
import CmuxNextDesign

/// Group by Status's marks (`WorkspaceRowStatusMarks`): only rows the status layout marks get the
/// marks view, so rows in every other mode keep exactly their subviews and layout.
extension WorkspaceRowView {
    private var statusMarksView: WorkspaceStatusMarksView? {
        subviews.first { $0.identifier == WorkspaceStatusMarksView.identifier } as? WorkspaceStatusMarksView
    }

    /// Shows `marks`, or hides the marks view. With marks the status glyph lives in the marks,
    /// so the row's own indicator and badges leave the state out (`statusMarksActivity`).
    func configureStatusMarks(_ marks: WorkspaceRowStatusMarks?) {
        guard let marks, !isShowingPlaceholder else {
            statusMarksView?.isHidden = true
            return
        }
        let view = statusMarksView ?? {
            let view = WorkspaceStatusMarksView()
            addSubview(view)
            return view
        }()
        view.isHidden = false
        view.configure(marks)
        activity.configure(.idle)
    }

    /// The activity the row's own badges draw: none when the status marks draw it.
    func statusMarksActivity(_ marks: WorkspaceRowStatusMarks?, _ activity: StatusIndicatorState) -> StatusIndicatorState {
        marks == nil || isShowingPlaceholder ? activity : .idle
    }

    /// Places the marks left of `trailing`, centered on `cy`, faded under the hover actions that
    /// start at `overlay`; returns the new trailing edge.
    func layoutStatusMarks(trailing: CGFloat, cy: CGFloat, overlay: CGFloat?, fades: Bool) -> CGFloat {
        guard let view = statusMarksView, !view.isHidden else { return trailing }
        let width = view.preferredWidth, height = SidebarStyle.statusGlyphSize
        view.frame = NSRect(x: (trailing - width).rounded(.down), y: (cy - height / 2).rounded(), width: width, height: height)
        view.needsLayout = true
        fadeOpacity(view, to: overlay.map { view.frame.maxX > $0 - Metrics.space1 } == true ? 0 : 1, fades: fades)
        return view.frame.minX - Metrics.space2
    }
}
