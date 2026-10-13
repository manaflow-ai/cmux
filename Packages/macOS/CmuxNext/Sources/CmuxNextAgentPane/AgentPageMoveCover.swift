public import AppKit

/// A page moved into another view (a parked New Tab spare adopted, cx-21zkz): WebKit shows nothing
/// there until the page draws again. The page stays clear until its next frame, or ``reveal(_:)``.
@MainActor
public enum AgentPageMoveCover {
    /// Keeps `view`'s page clear until its next frame; `drawn` runs then, in the transaction that shows it.
    public static func hide(_ view: AgentPaneView, until drawn: @escaping () -> Void) {
        view.pageContent.alphaValue = 0
        view.redraw.afterNextFrame { [weak view] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let view { reveal(view) }
            drawn()
            CATransaction.commit()
        }
    }

    /// Shows a page ``hide(_:until:)`` keeps clear.
    public static func reveal(_ view: AgentPaneView) {
        guard view.model.hasPainted else { return }
        view.pageContent.alphaValue = 1
    }
}
