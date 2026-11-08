import AppKit
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c: a closing pane on its close spring
/// shows only its own ground, read once at the close (its terminal's or page's, else its content area's), on the frame
/// its screen collapses (`ClosingPanes`). Its content hides at once (a hidden terminal stops drawing, a page window
/// orders out) and it takes no clicks (`hitTest`); its ring and dim are hidden with the retirement. A close taken back
/// ends it, and the same host shows its content again (`LayoutViewContext.host(for:)`).
extension PaneHostView {
    func showClosingGround() {
        guard !showsClosingGround else { return }
        let ground = content.paneGroundColor ?? clipView.layer?.backgroundColor
        showsClosingGround = true
        content.isHidden = true
        clipView.layer?.backgroundColor = ground
        applyChromeShape() // the pane's own rounded corners (its content rounded them while it showed)
    }

    func endClosingGround() {
        guard showsClosingGround else { return }
        showsClosingGround = false
        content.isHidden = false
        applyDockFill()
        applyChromeShape()
    }
}
