// cmux: Find in a Home chat (Cmd-F): the host's find bar drives it. Not a vendored file.
import AppKit

extension MessagesLabHomeView {
    /// cmux: searches the loaded messages for `query` (case-insensitive) and highlights every match;
    /// the first is current and scrolls into view. Empty clears the highlights.
    /// - Returns: The 1-based current match and the count (0 and 0: no match).
    @discardableResult
    public func find(_ query: String) -> (current: Int, total: Int) {
        controller.find.search(query)
        return controller.find.position
    }

    /// cmux: the next (`forward`) or previous match, wrapping; it scrolls into view.
    @discardableResult
    public func findStep(forward: Bool) -> (current: Int, total: Int) {
        controller.find.step(forward: forward)
        return controller.find.position
    }

    /// cmux: the messages changed while a find shows: its matches follow them.
    @discardableResult
    public func findRowsChanged() -> (current: Int, total: Int) {
        controller.find.rowsChanged()
        return controller.find.position
    }

    /// cmux: the current find's position (0 and 0: no find, or no match).
    public var findPosition: (current: Int, total: Int) { controller.find.position }
}
