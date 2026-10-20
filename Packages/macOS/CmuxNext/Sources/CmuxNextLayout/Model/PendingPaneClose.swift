/// A pane leaving its screen from the key that closes its last tab (or the pane) to the
/// daemon's tree without it (``LayoutModel/showPaneClose(_:)``).
///
/// A close is one gesture: the pane leaves the window and its chain takes the even sizes the
/// close leaves in the key's frame, so its neighbours spring into its space on one motion
/// (plans/cmux-next/close-animation/DESIGN.md). The daemon still owns the tree: the hidden pane
/// stays out of every snapshot until one no longer holds it, the close is refused
/// (``LayoutModel/cancelPaneClose(_:)``), or a snapshot after the accepted close shows what is true
/// (``LayoutModel/settlePaneClose(_:)``).
///
/// ```swift
/// guard let close = model.showPaneClose(pane) else { return } // a lone pane: nothing to show
/// // ... the close's reply:
/// model.settlePaneClose(close) // or model.cancelPaneClose(close) when it failed
/// ```
public struct PendingPaneClose: Hashable, Sendable {
    /// The pane that leaves.
    public let pane: PaneID
    /// The pane that takes the most of its space (the first pane of its sibling): the focus goes
    /// there when the closed pane had it.
    public let successor: PaneID?
    /// The transaction the close's sizing carries.
    let transaction: LayoutTransactionID
}
