import Foundation

/// Retains a bounded prefix for the artifact text view's single accessibility element.
struct ChatArtifactTextAccessibilityContent: Equatable, Sendable {
    static let maximumCharacterCount = 2_048

    private(set) var excerpt = ""
    private(set) var isTruncated = false

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let remaining = Self.maximumCharacterCount - excerpt.count
        guard remaining > 0 else {
            isTruncated = true
            return
        }
        let prefix = text.prefix(remaining)
        excerpt.append(contentsOf: prefix)
        if prefix.endIndex != text.endIndex {
            isTruncated = true
        }
    }
}
