import Foundation

/// Main-actor state retained while a pasteboard payload is prepared.
struct TextBoxPendingPasteReservation {
    let originalAttributedSelection: NSAttributedString
    var replacementRange: NSRange
    let usesMarker: Bool
    let sequence: UInt64
}
