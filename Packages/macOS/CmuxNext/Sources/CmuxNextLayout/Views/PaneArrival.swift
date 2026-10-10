import CoreGraphics

/// Where a pane added by a split starts (cx-f6i7): a zero-width (or
/// zero-height) sliver at the far edge of the space it takes from the pane
/// it split, so the pane grows in from that edge while the split pane
/// shrinks on the same spring and the divider between them slides from the
/// edge to its place. Nothing overlaps and no gap opens.
struct PaneArrival: Equatable {
    /// The new pane's first frame.
    var seed: CGRect
    /// How far the shared edge (and the divider on it) starts from its target.
    var edgeOffset: CGVector

    /// The arrival of a pane whose frame will be `target`, given every pane's
    /// frame before (`previous`) and after (`next`) the change; nil when no
    /// existing pane gave up the space (a strip column appended, a pane moved
    /// in from elsewhere), which then lands in place.
    static func of(target: CGRect, previous: [PaneID: CGRect], next: [PaneID: CGRect]) -> PaneArrival? {
        let slack: CGFloat = 1
        for (pane, before) in previous {
            guard let after = next[pane], before.insetBy(dx: -slack, dy: -slack).contains(target) else { continue }
            if target.minX >= after.maxX - slack {
                // Split right: the new pane comes in from the old right edge.
                return PaneArrival(seed: CGRect(x: target.maxX, y: target.minY, width: 0, height: target.height),
                                   edgeOffset: CGVector(dx: target.width, dy: 0))
            }
            if target.maxX <= after.minX + slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: 0, height: target.height),
                                   edgeOffset: CGVector(dx: -target.width, dy: 0))
            }
            if target.minY >= after.maxY - slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.maxY, width: target.width, height: 0),
                                   edgeOffset: CGVector(dx: 0, dy: target.height))
            }
            if target.maxY <= after.minY + slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: target.width, height: 0),
                                   edgeOffset: CGVector(dx: 0, dy: -target.height))
            }
        }
        return nil
    }
}
