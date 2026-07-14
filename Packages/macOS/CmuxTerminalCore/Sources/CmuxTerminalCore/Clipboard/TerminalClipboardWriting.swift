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
    /// Writes a string to the given ghostty clipboard location.
    ///
    /// When a one-shot capture is armed via
    /// ``captureNextStandardClipboardWrite(matching:_:)``, a standard-location
    /// write the capture's predicate accepts is diverted into the capture
    /// instead of the system pasteboard; a write it rejects reaches the
    /// pasteboard and leaves the capture armed.
    func writeString(_ string: String, to location: ghostty_clipboard_e)

    /// Arms a one-shot diversion of the next matching standard-clipboard
    /// write that happens while `action` runs, returning the diverted string.
    ///
    /// `predicate` decides whether a given write is the one this capture is
    /// waiting for; non-matching writes (e.g. a concurrent user copy) pass
    /// through to the real pasteboard un-swallowed.
    ///
    /// Returns `nil` when `action` reports failure, no matching write
    /// occurred, or another capture is already in flight (overlapping
    /// captures are rejected rather than allowed to steal each other's
    /// writes; callers treat `nil` as "fall back to a non-capture read").
    @discardableResult
    func captureNextStandardClipboardWrite(
        matching predicate: @escaping @Sendable (String) -> Bool,
        _ action: () -> Bool
    ) -> String?
}

extension TerminalClipboardWriting {
    /// Arms a one-shot diversion of the next standard-clipboard write,
    /// accepting any payload. Prefer the `matching:` variant with the
    /// narrowest predicate the expected payload allows.
    @discardableResult
    public func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String? {
        captureNextStandardClipboardWrite(matching: { _ in true }, action)
    }
}
