import Foundation

/// A language option explicitly shown for workspace/tab auto-naming.
public struct AutoNamingLanguageOption: Sendable, Hashable {
    /// Stored setting value.
    public let slug: String
    /// BCP-47 language tag passed to the naming prompt.
    public let bcp47Tag: String
    /// English language name used in the LLM prompt.
    public let promptName: String

    /// Creates a selectable auto-naming language option.
    /// - Parameters:
    ///   - slug: Stored setting value.
    ///   - bcp47Tag: BCP-47 language tag passed to the naming prompt.
    ///   - promptName: English language name used in the LLM prompt.
    public init(slug: String, bcp47Tag: String, promptName: String) {
        self.slug = slug
        self.bcp47Tag = bcp47Tag
        self.promptName = promptName
    }
}
