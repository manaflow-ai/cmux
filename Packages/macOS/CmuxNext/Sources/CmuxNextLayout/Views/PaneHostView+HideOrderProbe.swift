import AppKit
import CmuxNextDesign

/// A measure branch's switch (no PR): `debug.motion` kind `probe.hideFirst` sets it through each pane host that a
/// window shows. The pane motion of the host's screen keeps it (``PaneCommitMotion/hidesFirst``); a host in no screen
/// has none.
extension PaneHostView: MotionHideOrderSwitching {
    var hidesBeforeMovesGo: Bool {
        get { (superview as? ScreenContentView)?.zoomDim.motion.hidesFirst ?? false }
        set { (superview as? ScreenContentView)?.zoomDim.motion.hidesFirst = newValue }
    }
}
