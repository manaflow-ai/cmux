import AppKit

/// Row view drawing the same selection treatment as the Files sidebar.
@MainActor
final class CloudTreeRowView: NSTableRowView {
    /// Hover and reorder state belong to the cell and outline, so row views
    /// can use AppKit's reuse pool without retaining a previous item.
    static func reusable(in outlineView: NSOutlineView) -> CloudTreeRowView {
        let identifier = NSUserInterfaceItemIdentifier("CloudTreeRow")
        let row = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? CloudTreeRowView) ?? CloudTreeRowView()
        row.identifier = identifier
        return row
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let insetRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
        // Gray in both focus states (no accent blue); keyboard focus reads as a
        // slightly stronger shade.
        NSColor.labelColor.withAlphaComponent(isKeyboardFocusActive ? 0.12 : 0.07).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return window?.isKeyWindow == true && window?.firstResponder === outlineView
            }
            view = candidate.superview
        }
        return false
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // The gray highlight keeps normal label colors; .emphasized would flip
        // the text to white as if on an accent fill.
        .normal
    }
}
