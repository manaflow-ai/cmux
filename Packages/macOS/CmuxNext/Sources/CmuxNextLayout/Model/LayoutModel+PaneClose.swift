/// A pane close shown in the key's turn (plans/cmux-next/close-animation/DESIGN.md). Red: not
/// implemented yet; the tests in PaneCloseMotionTests fail.
extension LayoutModel {
    /// Hides `pane` from the shown screens with its chain's close sizing, in this turn.
    public func showPaneClose(_ pane: PaneID) -> PendingPaneClose? { nil }
    /// The daemon accepted the close.
    public func settlePaneClose(_ close: PendingPaneClose) {}
    /// The daemon refused the close.
    public func cancelPaneClose(_ close: PendingPaneClose) {}
    /// Whether `pane` is hidden by a pending close.
    public func isClosing(_ pane: PaneID) -> Bool { false }
}
