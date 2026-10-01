import AppKit
import CmuxFoundation

/// Owns destination feedback for one native drag generation. Source completion
/// and destination completion converge on the coordinator's existing teardown.
@MainActor
final class CloudTreeReorderPresentation {
    private weak var outline: CloudTreeNSOutlineView?
    private let indicator = SidebarReorderIndicatorView()
    private var destination: (sequence: Int, drop: CloudSidebarOrganizationDrop)?

    /// Creates presentation feedback attached to the outline view.
    init(outline: CloudTreeNSOutlineView) {
        self.outline = outline
        outline.addSubview(indicator)
    }

    /// Displays the insertion line for the current drag sequence.
    func show(_ drop: CloudSidebarOrganizationDrop, sequence: Int) {
        destination = (sequence, drop)
        outline?.addSubview(indicator, positioned: .above, relativeTo: nil)
        indicator.accentColor = AppDelegate.shared?.accentColor ?? CmuxAccentColor()
        indicator.updateColor()
        layout()
    }

    /// Hides the insertion line, optionally only for a matching drag sequence.
    func clear(sequence: Int? = nil) {
        if let sequence, let destination, destination.sequence != sequence { return }
        destination = nil
        indicator.isHidden = true
    }

    /// Recomputes the indicator position after outline rows change.
    func layout() {
        guard let outline, let destination else { return }
        let drop = destination.drop
        let children = drop.children
        let y: CGFloat
        if drop.childIndex < children.count {
            let row = outline.row(forItem: children[drop.childIndex])
            guard row >= 0 else { clear(); return }
            y = outline.rect(ofRow: row).minY
        } else if let last = children.last {
            var row = outline.row(forItem: last)
            guard row >= 0 else { clear(); return }
            let level = outline.level(forRow: row)
            while row + 1 < outline.numberOfRows, outline.level(forRow: row + 1) > level {
                row += 1
            }
            y = outline.rect(ofRow: row).maxY - SidebarReorderIndicatorView.thickness
        } else { clear(); return }
        indicator.position(in: outline.visibleRect, at: y)
        indicator.isHidden = false
    }

}
