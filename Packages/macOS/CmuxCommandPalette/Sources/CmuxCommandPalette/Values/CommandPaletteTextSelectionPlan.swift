import Foundation

/// The resolved outcome of the command palette's pending text-selection gating.
///
/// When a palette input is about to take focus, the host has a queued
/// ``CommandPaletteTextSelectionBehavior`` and asks the presentation model
/// whether that behavior applies in the current ``CommandPaletteMode``. The
/// model returns this plan; the host then either skips (leaving the queued
/// behavior pending for a later focus) or applies the named selection to the
/// live field editor and clears the pending behavior.
///
/// Keeping the decision a pure value (no `NSRange`, no AppKit) lets the gating
/// rules be unit-tested against the package's own ``CommandPaletteMode`` and
/// ``CommandPaletteTextSelectionBehavior`` while the field-editor mutation stays
/// app-side. The `selectAll`/`caretAtEnd` cases name the selection the host
/// applies by converting to a range over the editor's current length.
public enum CommandPaletteTextSelectionPlan: Sendable, Equatable {
    /// The queued behavior does not apply in the current mode; the host leaves it
    /// pending and applies nothing.
    case skip
    /// Select the whole field-editor text.
    case selectAll
    /// Place the caret at the end of the field-editor text without selecting.
    case caretAtEnd
}
