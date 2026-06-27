import Foundation

/// Language instruction carried from the app probe into the naming prompt.
struct AutoNamingPromptLanguage: Equatable, Sendable {
    static let fallback = AutoNamingPromptLanguage(name: "English", tag: "en")

    var name: String
    var tag: String

    init(name: String, tag: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedTag.isEmpty {
            self = Self.fallback
        } else {
            self.name = trimmedName
            self.tag = trimmedTag
        }
    }
}
