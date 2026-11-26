import Foundation

/// Describes one pending-paste marker replacement needed before a user edit.
struct TextBoxPendingPasteEditRestoration {
    let id: UUID
    let markerRange: NSRange
    let originalSelection: NSAttributedString
}
