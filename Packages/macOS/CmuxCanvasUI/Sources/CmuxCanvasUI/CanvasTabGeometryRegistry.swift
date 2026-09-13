import AppKit

/// Reads hit regions from the views currently on screen. SwiftUI preference
/// snapshots can lag scrolling, resizing, and canvas magnification.
@MainActor
final class CanvasTabGeometryRegistry {
    private let views = NSHashTable<CanvasTabHitRegionView.RegionView>.weakObjects()

    func register(_ view: CanvasTabHitRegionView.RegionView) {
        views.add(view)
    }

    func unregister(_ view: CanvasTabHitRegionView.RegionView) {
        views.remove(view)
    }

    func hitRegions(in bar: NSView) -> CanvasTabHitRegions {
        var result = CanvasTabHitRegions()
        for view in views.allObjects where view.isDescendant(of: bar) && !isHiddenOrHasHiddenAncestor(view) {
            let frame = view.convert(view.bounds, to: bar)
            guard !frame.isEmpty else { continue }
            switch view.kind {
            case .tab:
                result.tabFrames[view.tabId] = frame
            case .close:
                result.closeFrames[view.tabId] = frame.insetBy(dx: -4, dy: -7)
            }
        }
        return result
    }

    private func isHiddenOrHasHiddenAncestor(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alphaValue <= 0 { return true }
            current = candidate.superview
        }
        return false
    }
}
