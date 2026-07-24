import Foundation

/// Main-actor state retained while a pasteboard payload is prepared.
struct TextBoxPendingPasteReservation {
    let originalAttributedSelection: NSAttributedString
    let originalSelectionRange: NSRange
    let stagedSelectionRange: NSRange
}
