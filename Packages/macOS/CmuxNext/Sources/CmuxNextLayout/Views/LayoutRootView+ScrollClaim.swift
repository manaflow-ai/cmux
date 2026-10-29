import AppKit
import CmuxNextDesign

/// Pane content that scrolls sideways itself keeps a horizontal scroll (MARKDOWN-TABLE-SCROLL,
/// user 2026-10-20): a wide Markdown table or code line under the pointer, which the strip would
/// otherwise take before the pane's view saw the gesture. Only `layout.scrollModifier` `none`
/// asks: with `command` every plain scroll over a pane is the pane's already.
extension LayoutRootView {
    /// Whether the active screen's pane under `locationInWindow` claims a horizontal scroll there
    /// (``HorizontalScrollClaiming``): hit-tests that pane's host and asks the nearest claiming view
    /// at or above the hit view, up to the host.
    func paneContentClaimsHorizontalScroll(at locationInWindow: NSPoint) -> Bool {
        guard let active = model.activeScreenID, let screen = screenViews[active],
              let pane = screen.pane(at: screen.convert(locationInWindow, from: nil)),
              let host = context.hosts[pane], let parent = host.superview,
              var view = host.hitTest(parent.convert(locationInWindow, from: nil)) else { return false }
        while view !== host {
            if let claiming = view as? any HorizontalScrollClaiming {
                return claiming.claimsHorizontalScroll(at: view.convert(locationInWindow, from: nil))
            }
            guard let next = view.superview else { return false }
            view = next
        }
        return false
    }
}
