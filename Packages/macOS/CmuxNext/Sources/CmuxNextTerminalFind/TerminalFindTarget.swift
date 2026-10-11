/// The terminal a ``TerminalFindController`` drives.
///
/// The live conformer is the terminal session, which forwards to Ghostty's
/// search bindings on its current surface. Results come back through
/// ``TerminalFindController/receiveTotal(_:)`` and
/// ``TerminalFindController/receiveSelected(_:)``.
@MainActor
public protocol TerminalFindTarget: AnyObject {
    /// Searches for `needle` and highlights every match. An empty needle
    /// stops the search.
    func setSearchNeedle(_ needle: String)
    /// Selects the next or previous match; the terminal scrolls it into view.
    func navigateSearch(_ direction: TerminalFindDirection)
    /// Ends the search and removes every match highlight.
    func endSearch()
    /// Removes the terminal's text selection.
    func clearSelection()
    /// True while another mode owns the selection (copy mode's `v`), so
    /// closing find must leave it.
    var isSelectionPinned: Bool { get }
    /// Gives the keyboard back to the terminal.
    func focusTerminal()
}
