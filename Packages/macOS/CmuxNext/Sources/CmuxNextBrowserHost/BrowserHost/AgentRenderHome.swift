package import AppKit

/// A view that shows tab chromes (a pane): it takes a chrome back from an
/// agent render window when its window draws again.
///
/// ``AgentRenderWindows`` moves a WebKit tab out of a minimized or fully
/// covered window while an agent drives it, and calls ``takeBack(_:)`` on the
/// nearest such ancestor of the tab's old place once that window draws.
@MainActor package protocol AgentRenderHome: AnyObject {
    /// The window of this home draws again: show `view` here if it is still
    /// this home's selected tab.
    /// - Parameter view: The chrome that left for a render window.
    func takeBack(_ view: NSView)
}
