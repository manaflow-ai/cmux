import AppKit

/// Owns destination feedback for one native drag generation. Source completion
/// and destination completion converge on the coordinator's existing teardown.
@MainActor
final class CloudTreeReorderPresentation {
    private weak var outline: CloudTreeNSOutlineView?
    private let indicator = SidebarReorderIndicatorView()
    private var destination: (sequence: Int, drop: CloudSidebarOrganizationDrop)?

    init(outline: CloudTreeNSOutlineView) {
        self.outline = outline
        outline.addSubview(indicator)
    }

    func show(_ drop: CloudSidebarOrganizationDrop, sequence: Int) {
        destination = (sequence, drop)
        outline?.addSubview(indicator, positioned: .above, relativeTo: nil)
        indicator.updateColor()
        layout()
    }

    func isCurrent(_ info: (any NSDraggingInfo)?) -> Bool {
        guard let info, let destination else { return true }
        return destination.sequence == info.draggingSequenceNumber
    }

    func clear(sequence: Int? = nil) {
        if let sequence, let destination, destination.sequence != sequence { return }
        destination = nil
        indicator.isHidden = true
    }

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

    func ended(_ info: any NSDraggingInfo) {
        if let destination, destination.sequence != info.draggingSequenceNumber { return }
        clear(sequence: info.draggingSequenceNumber)
        guard let outline,
              let source = info.draggingSource as? CloudTreeNSOutlineView, source === outline,
              let session = source.activeNativeDragSession,
              session.draggingSequenceNumber == info.draggingSequenceNumber,
              let coordinator = source.activeNativeDragCoordinator as? CloudTreeOutlineView.Coordinator else { return }
        // draggingEnded is a terminal destination callback, including Escape.
        // It remains available if a reconstructed data source lost endedAt.
        coordinator.outlineView(source, draggingSession: session, endedAt: .zero, operation: [])
    }
}
