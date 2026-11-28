import CmuxNextBridge
import CmuxNextTabs

/// Draws the outline of a tab drag's current preview in the winner
/// window's layout overlay (above Chromium pages, R84): the layout's own
/// pane zones, or a strip's insert slot. The sidebar lights its own slot.
/// A stay labels the outline (tab-dnd); a refused zone draws none.
@MainActor
enum TabDragOutline {
    /// `layout` returns the window's cached layout drop adapter.
    static func update(_ drag: TabDragSession.Drag, layout: (WindowController) -> LayoutTabDropTarget) {
        var outlined: LayoutTabDropTarget?
        if let winner = drag.winner, let window = winner.window {
            let adapter = layout(window)
            if !drag.resolution.preview.highlights {
                // The layout drew the zone in its hit test: take it down,
                // and keep the layout (its held zone) for the next one.
                if winner.provider === adapter {
                    adapter.hideOutline()
                    outlined = adapter
                }
            } else if winner.provider === adapter {
                outlined = adapter
            } else if winner.provider is TabStripView {
                adapter.outline(screenRect: winner.proposal.highlightFrame)
                outlined = adapter
            }
        }
        if let previous = drag.outlinedLayout, previous !== outlined { previous.dropExited() }
        drag.outlinedLayout = outlined
        switch drag.resolution.preview {
        case .stay: outlined?.note(TabDropStrings.stay, refused: false)
        case .target, .refused, .newWindow, .none: break
        }
    }
}
