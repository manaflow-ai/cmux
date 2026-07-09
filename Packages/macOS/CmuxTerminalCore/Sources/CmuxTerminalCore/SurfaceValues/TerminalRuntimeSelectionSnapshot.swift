public import Foundation

/// A point-in-time read of the runtime surface's current text selection.
///
/// Produced by reading `ghostty_surface_read_selection` off the live
/// `ghostty_surface_t`. The accessibility text-area exposure and the
/// `NSTextInputClient` selection/substring/coordinate methods consume this
/// value; lifted verbatim from the view-private `SelectionSnapshot` that lived
/// in `Sources/GhosttyTerminalView.swift`.
public struct TerminalRuntimeSelectionSnapshot: Equatable, Sendable {
    /// The selected character range in the surface's offset space.
    public let range: NSRange

    /// The selected text, decoded as UTF-8. Empty when nothing is selected.
    public let string: String

    /// The top-left pixel origin of the selection, in surface coordinates.
    public let topLeft: CGPoint

    /// Creates a selection snapshot.
    public init(range: NSRange, string: String, topLeft: CGPoint) {
        self.range = range
        self.string = string
        self.topLeft = topLeft
    }
}
