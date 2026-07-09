public import Foundation

/// A pending inline autocompletion shown after the typed query in the omnibar
/// field editor: `typedText` is what the user typed, `displayText` is the full
/// text rendered in the field, and `acceptedText` is the value committed on
/// Return or Tab.
public struct OmnibarInlineCompletion: Equatable, Sendable {
    public let typedText: String
    public let displayText: String
    public let acceptedText: String

    public init(typedText: String, displayText: String, acceptedText: String) {
        self.typedText = typedText
        self.displayText = displayText
        self.acceptedText = acceptedText
    }

    /// The UTF-16 range of the inline suffix (the portion past the typed text),
    /// used to select or replace the completion in the field editor.
    public var suffixRange: NSRange {
        let typedCount = typedText.utf16.count
        let fullCount = displayText.utf16.count
        return NSRange(location: typedCount, length: max(0, fullCount - typedCount))
    }
}
