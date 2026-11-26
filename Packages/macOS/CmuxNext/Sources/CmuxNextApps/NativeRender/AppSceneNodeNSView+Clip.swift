import AppKit

/// `clipped`: the node's children sit in a ``AppSceneClipView`` cut to the node's bounds and
/// `cornerRadius`, so a child's slide or scale transition, its glow or a particle field stays inside,
/// while the node's own glow (a shadow on its own layer, outside the clip) still shows.
extension AppSceneNodeNSView {
    /// Puts the children into the clip container, or back, as `clipped` says (on each configure).
    func configureClip() {
        let wanted = node.clipped
        let radius = CGFloat(max(0, node.number("cornerRadius") ?? 0))
        guard hostsChildrenInSelf else {
            // A panel's children sit in its own content view: that view clips.
            childHost.wantsLayer = true
            childHost.layer?.masksToBounds = wanted
            childHost.layer?.cornerCurve = .continuous
            childHost.layer?.cornerRadius = wanted ? radius : 0
            return
        }
        if wanted, clipView == nil {
            let clip = AppSceneClipView(frame: bounds)
            addSubview(clip)
            moveChildren(from: self, to: clip)
            clipView = clip
            needsLayout = true
        } else if !wanted, let clip = clipView {
            clipView = nil
            moveChildren(from: clip, to: self)
            clip.removeFromSuperview()
            needsLayout = true
        }
        clipView?.layer?.cornerRadius = radius
    }

    /// Moves the scene children (in order) from `old` to `new`; one on its way out leaves now.
    private func moveChildren(from old: NSView, to new: NSView) {
        for child in old.subviews.compactMap({ $0 as? AppSceneNodeNSView }) {
            if child.exitHost != nil {
                child.cancelExit()
                child.removeFromSuperview()
            } else {
                new.addSubview(child)
            }
        }
    }
}

/// The container a `clipped` node's children sit in: its bounds, cut to the node's corner radius.
/// It takes no click of its own (a click between children goes to the node).
final class AppSceneClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
