import CoreGraphics
#if os(iOS)
import UIKit
#endif

/// Width candidates available when a transcript table cell is configured.
///
/// The bubble cap is `width * theme.bubbleMaxWidthFraction`, and a
/// non-positive width resolves the `\.chatBubbleMaxWidth` environment to
/// `.infinity`, leaving the bubble uncapped.
///
/// On the first layout pass of a freshly-inserted pending row (the "on send"
/// case) the transcript table's own `bounds.width` is not resolved yet (0), so
/// the bubble measures uncapped: it renders full-width, then snaps to the cap
/// once `bounds.width` resolves on the next pass. Falling back to the hosting
/// window (then its screen) width yields a correct provisional cap on the
/// first render and removes the wide-then-narrow snap.
struct ChatContainerWidth {
    let boundsWidth: CGFloat
    let windowWidth: CGFloat?
    let screenWidth: CGFloat?

    #if os(iOS)
    @MainActor
    init(tableView: UITableView) {
        self.boundsWidth = tableView.bounds.width
        self.windowWidth = tableView.window?.bounds.width
        // Cells can be configured before the table enters a window; keep the first cap finite anyway.
        self.screenWidth = tableView.window?.windowScene?.screen.bounds.width ?? UIScreen.main.bounds.width
    }
    #endif

    init(boundsWidth: CGFloat, windowWidth: CGFloat?, screenWidth: CGFloat?) {
        self.boundsWidth = boundsWidth
        self.windowWidth = windowWidth
        self.screenWidth = screenWidth
    }

    /// First positive width among the table bounds, hosting window, and its
    /// screen; `0` only when none is known yet.
    var effectiveWidth: CGFloat {
        if boundsWidth > 0 { return boundsWidth }
        if let windowWidth, windowWidth > 0 { return windowWidth }
        if let screenWidth, screenWidth > 0 { return screenWidth }
        return 0
    }
}
