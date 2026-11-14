public import AppKit

/// Paste is enabled from the first-run panel only when the message box has
/// something to take (text, or files and pictures Home's intake accepts).
extension HomeNativeTranscriptView: NSMenuItemValidation {
    /// Enables ``paste(_:)`` when there is something to paste; other items keep AppKit's default.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(paste(_:)) else { return true }
        return canPasteIntoPrimaryInput
    }
}
