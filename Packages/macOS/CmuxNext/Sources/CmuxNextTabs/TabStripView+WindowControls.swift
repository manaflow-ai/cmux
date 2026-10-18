public import AppKit
import CmuxNextDesign

// A strip under the window's traffic lights (minimal titlebar, sidebar
// hidden, the top-left pane) starts its tabs after them. Only strips whose
// shown part overlaps the traffic lights get the inset, so it follows sidebar
// show and hide, splits, column scrolling and fullscreen. A strip in a pane on
// a layout spring (the strip camera scrolling, a split sliding in) measures
// where its pane will rest (`RestingPlacement`): it lays out once, for its
// final place, and its tabs then move with the column, never pinned to the
// traffic lights while the column slides under them or under the sidebar.
extension TabStripView {
    /// Re-checks the traffic lights after the strip moved in its window
    /// without a resize (the App calls it when the pane's window frame
    /// changes); relays out only when the inset changes.
    public func updateWindowControlsAvoidance() {
        guard computeWindowControlsInset() != windowControlsInset else { return }
        needsLayout = true
    }

    /// Leading points to keep clear so the first tab starts a little after
    /// the traffic lights; 0 when the strip is not under them.
    func computeWindowControlsInset() -> CGFloat {
        guard let window else { return 0 }
        let host = window as? TitlebarAccessoryHosting
        let (strip, shown) = restingWindowRect()
        return Self.windowControlsInset(strip: strip, shown: shown, lights: WindowTitlebar.trafficLightsFrame(in: window),
                                        accessory: host?.titlebarAccessoryFrame, padding: metrics.stripHorizontalPadding)
    }

    /// The strip's frame in window coordinates where its pane will rest, and the window
    /// area its ancestors above that pane show (their bounds, which do not move with it).
    private func restingWindowRect() -> (strip: CGRect, shown: CGRect) {
        var placement: (any RestingPlacement)?
        var ancestor = superview
        while let view = ancestor, placement == nil {
            placement = view as? RestingPlacement
            ancestor = view.superview
        }
        var strip = convert(bounds, to: nil)
        if let placement, let parent = placement.superview {
            let now = parent.convert(placement.frame, to: nil)
            let rest = parent.convert(placement.frame.offsetBy(dx: placement.restOffset.dx, dy: placement.restOffset.dy), to: nil)
            strip = strip.offsetBy(dx: rest.minX - now.minX, dy: rest.minY - now.minY)
        }
        var shown = CGRect.infinite
        while let view = ancestor {
            shown = shown.intersection(view.convert(view.bounds, to: nil))
            ancestor = view.superview
        }
        return (strip, shown)
    }

    /// Leading points a strip at `strip` (window coordinates) keeps clear of
    /// the traffic lights and the window's titlebar accessory where they lie
    /// over its `shown` part (pure).
    static func windowControlsInset(strip: CGRect, shown: CGRect, lights: CGRect?, accessory: CGRect?, padding: CGFloat) -> CGFloat {
        let visible = strip.intersection(shown)
        let obstacles = [lights, accessory].compactMap { $0 }.filter { frame in
            !visible.isNull && visible.minY < frame.maxY && visible.maxY > frame.minY && visible.minX < frame.maxX && visible.maxX > frame.minX
        }
        guard let right = obstacles.map(\.maxX).max() else { return 0 }
        let clear = right + Metrics.space3 - strip.minX - padding
        return max(0, (clear * 2).rounded(.up) / 2)
    }

    /// Whether empty strip space acts as a titlebar right now.
    var actsAsTitlebar: Bool {
        dragsWindowFromEmptySpace && WindowTitlebar.isInTopRow(self)
    }
}
