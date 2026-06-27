import Foundation

/// The effective language instruction for one auto-naming pass.
public struct AutoNamingResolvedLanguage: Sendable, Equatable {
    /// Human-readable English language name for the prompt.
    public let promptName: String
    /// BCP-47 language tag for deterministic logging and prompts.
    public let bcp47Tag: String

    /// Creates a resolved auto-naming language.
    /// - Parameters:
    ///   - promptName: Human-readable English language name for the prompt.
    ///   - bcp47Tag: BCP-47 language tag for deterministic logging and prompts.
    public init(promptName: String, bcp47Tag: String) {
        self.promptName = promptName
        self.bcp47Tag = bcp47Tag
    }
}
