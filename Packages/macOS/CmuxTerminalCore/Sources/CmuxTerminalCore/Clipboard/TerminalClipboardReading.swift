public import AppKit
public import GhosttyKit

/// Read-side clipboard capability consumed by the ghostty runtime callbacks
/// and the surface view's paste paths.
///
/// Implemented by `TerminalPasteboardService` in `CmuxTerminalServices` and
/// injected wherever paste text must be resolved, so callers never touch
/// `NSPasteboard` flavor-priority logic directly.
///
/// Isolation: requirements are synchronous and the conforming service is
/// `Sendable` because ghostty clipboard callbacks arrive on non-main threads
/// and cannot await.
public protocol TerminalClipboardReading: AnyObject, Sendable {
    /// The pasteboard backing a ghostty clipboard location, or `nil` for
    /// locations cmux does not support.
    func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard?

    /// The terminal-paste text for the pasteboard's current contents,
    /// applying cmux's flavor-priority rules (file URLs, image-only guard,
    /// plain-versus-rich fidelity).
    func stringContents(from pasteboard: NSPasteboard) -> String?

    /// The best plain-text flavor only, bypassing rich-text resolution.
    func fallbackPlainTextContents(from pasteboard: NSPasteboard) -> String?

    /// Whether the location's pasteboard currently holds pasteable contents.
    func hasString(for location: ghostty_clipboard_e) -> Bool
}
