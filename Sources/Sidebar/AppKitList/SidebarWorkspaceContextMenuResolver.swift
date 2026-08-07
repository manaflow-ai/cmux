import AppKit

/// Resolves a native sidebar row's most specific context-menu provider.
///
/// AppKit sends Control-click menu lookup to the table even when a descendant
/// owns the menu. Walking from the hit-tested view back to the row preserves
/// nested providers (for example, checklist items) while making the row menu
/// the deterministic fallback.
@MainActor
struct SidebarWorkspaceContextMenuResolver {
    let rowView: NSView

    func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinateView = rowView.superview else {
            return rowView.menu(for: event)
        }
        // NSView.hitTest(_:) takes a point in the receiver's superview
        // coordinate system, not the receiver's local coordinates.
        let point = coordinateView.convert(event.locationInWindow, from: nil)
        var candidate = rowView.hitTest(point)
        while let view = candidate, view !== rowView {
            // Generic AppKit controls can synthesize an empty menu even when
            // they do not own a context-menu action. Keep walking so the
            // nearest actionable ancestor gets the request.
            if let menu = view.menu(for: event), !menu.items.isEmpty {
                return menu
            }
            candidate = view.superview
        }
        return rowView.menu(for: event)
    }
}
