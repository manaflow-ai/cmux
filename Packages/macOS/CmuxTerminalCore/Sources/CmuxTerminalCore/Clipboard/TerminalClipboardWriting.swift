public import GhosttyKit

/// Write-side clipboard capability consumed by the ghostty runtime's
/// write-clipboard callback and by app flows that intercept it.
///
/// Implemented by `TerminalPasteboardService` in `CmuxTerminalServices`.
///
/// Isolation: requirements are synchronous and the conforming service is
/// `Sendable` because the ghostty write-clipboard callback arrives on
/// non-main threads and cannot await.
public protocol TerminalClipboardWriting: AnyObject, Sendable {
    /// Publishes every supplied representation as one pasteboard item.
    ///
    /// - Parameters:
    ///   - representations: Textual MIME variants for the same clipboard
    ///     payload, in runtime preference order.
    ///   - location: The system or selection clipboard to update.
    func writeRepresentations(
        _ representations: [TerminalClipboardRepresentation],
        to location: ghostty_clipboard_e
    )

    /// Writes a string to the given ghostty clipboard location.
    ///
    /// When a one-shot capture is armed via
    /// ``captureNextStandardClipboardWrite(_:)``, a standard-location write is
    /// diverted into the capture instead of the system pasteboard.
    func writeString(_ string: String, to location: ghostty_clipboard_e)

    /// Arms a one-shot diversion of the next standard-clipboard write that
    /// happens while `action` runs, returning the diverted string.
    ///
    /// Returns `nil` when `action` reports failure or no write occurred.
    @discardableResult
    func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String?
}
