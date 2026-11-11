import AppKit

/// Screen views: which one shows.
extension LayoutRootView {
    /// Shows `active` and hides every other screen, in this turn. A change of screen has no transition (Lawrence
    /// 2026-11-10: "we should remove changing screen animation"): every screen view fills the root at full alpha, and
    /// only `isHidden` tells the shown one from the others. Chrome switches tabs the same way: the tab's view shows
    /// in the turn that activates it. Work is O(screens that change): one that stays hidden is not touched.
    func showScreen(_ active: ScreenID?) {
        for (id, view) in screenViews {
            let hides = id != active
            guard view.isHidden != hides else { continue }
            // AppKit tells the screen and its views in this call (`viewDidHide`, `viewDidUnhide`): the screen that hides
            // gives back its divider hover and resize cursor (`ScreenContentView.viewDidHide`), and each scrollbar's
            // thumb gives or takes its occluder (`StripScrollbarView`). Neither is done again here.
            view.isHidden = hides
            if hides {
                // No frame steps a hidden screen: its cameras and its pane springs land now, not when it shows again
                // (a switch shows a screen at rest).
                view.settleCameras()
                view.settleMotion()
                // Nor does it land a resize drag: its pages lay out now.
                view.finishResizeGesture()
            } else {
                // It shows under a possibly still pointer: its divider hover and resize cursor follow.
                view.refreshDividerHover()
            }
            setNeedsOverlaySync()
        }
    }

    /// Every screen view fills the root, hidden ones too: a hidden screen keeps its geometry at the root's size
    /// (``navigationFrames(ofScreenContaining:)``), and the one a switch shows is already in place.
    func fitScreensToBounds() {
        for view in screenViews.values {
            if view.frame.origin != bounds.origin { view.setFrameOrigin(bounds.origin) }
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
        }
    }
}
