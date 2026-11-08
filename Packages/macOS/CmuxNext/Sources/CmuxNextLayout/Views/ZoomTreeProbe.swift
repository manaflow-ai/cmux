#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextDesign

// ZOOM VARIANTS 3 key-turn attribution (never merged): marks every view tree change (a subview added or removed, a
// host or ring hidden or shown) on the zoom path as a `debug.motion` span, so a profile names the change that makes
// AppKit rebuild the window's layer tree (`_buildLayerTree`) in the key turn's commit.
extension ScreenContentView {
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        MotionTrace.interval("zk.tree.add.\(type(of: subview))") {}
    }

    override func willRemoveSubview(_ subview: NSView) {
        MotionTrace.interval("zk.tree.rm.\(type(of: subview))") {}
        super.willRemoveSubview(subview)
    }
}

extension LayoutRootView {
    override public func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        MotionTrace.interval("zk.tree.root.add.\(type(of: subview))") {}
    }

    override public func willRemoveSubview(_ subview: NSView) {
        MotionTrace.interval("zk.tree.root.rm.\(type(of: subview))") {}
        super.willRemoveSubview(subview)
    }
}

extension OverlayPlane {
    override public func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        MotionTrace.interval("zk.tree.plane.add.\(type(of: subview))") {}
    }

    override public func willRemoveSubview(_ subview: NSView) {
        MotionTrace.interval("zk.tree.plane.rm.\(type(of: subview))") {}
        super.willRemoveSubview(subview)
    }
}

extension PaneHostView {
    override func viewDidHide() {
        super.viewDidHide()
        MotionTrace.interval("zk.tree.host.hide") {}
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        MotionTrace.interval("zk.tree.host.unhide") {}
    }
}

extension PaneOverlayView {
    override func viewDidHide() {
        super.viewDidHide()
        MotionTrace.interval("zk.tree.ring.hide") {}
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        MotionTrace.interval("zk.tree.ring.unhide") {}
    }
}
#endif
