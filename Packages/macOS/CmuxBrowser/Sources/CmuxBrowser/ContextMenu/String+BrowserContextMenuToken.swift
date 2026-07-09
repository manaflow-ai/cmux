import Foundation

extension String {
    /// The comparison token used to classify a browser context-menu item by its
    /// identifier, title, or action-selector name: lowercase the string and strip
    /// every non-alphanumeric Unicode scalar, so spacing, punctuation, and case
    /// never affect matching. Empty input yields an empty token.
    public var normalizedBrowserContextMenuToken: String {
        let lowered = lowercased()
        let alphanumerics = CharacterSet.alphanumerics
        let scalars = lowered.unicodeScalars.filter { alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
