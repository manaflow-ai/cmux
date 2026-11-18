import AppKit
import CmuxNextDesign

/// The ground a late pane shows (``PaneHostView/showsLateGround``).
extension PaneHostView {
    /// Shows the ground over the content's own area while the pane is late, and takes it away when it is not. Runs in
    /// each layout pass of the pane (`applyChromeShape`), so it reads the ground's color and rect only while the
    /// ground shows: a pane that is not late pays for one check.
    func applyLateGround() {
        guard showsLateGround else { return clipView.showLateGround(nil) }
        clipView.showLateGround(lateGroundColor, over: lateGroundRect)
    }

    /// The opaque ground a late pane shows: its content's own (a terminal's background, a page's color), else the
    /// window's ground (a see-through pane has none of its own, and a clear cover would show the old picture).
    private var lateGroundColor: CGColor {
        if let ground = content.paneGroundColor, ground.alpha >= 1 { return ground }
        return performWithTheme { Palette.surfaceBackground.withAlphaComponent(1).cgColor }
    }

    /// The content's own area in the clip: the content less its tabs (a strip at its top or bottom edge, a list at
    /// its leading edge), as `applyChromeShape()` measures them for held content.
    private var lateGroundRect: CGRect {
        let tabs = content.paneGroundInsets, area = content.frame
        let top = tabs?.top ?? headerHeight, leading = tabs?.leading ?? 0
        return CGRect(x: area.minX + leading, y: area.minY + top, width: area.width - leading, height: area.height - top - footerHeight)
    }
}
