import Foundation

/// Catalog of explicit language choices for workspace/tab auto-naming.
public struct AutoNamingLanguageCatalog: Sendable {
    /// Sentinel meaning "follow the user's system language."
    public static let autoSlug = "auto"

    /// Explicit language choices shown in Settings.
    public let explicitOptions: [AutoNamingLanguageOption]

    /// Creates the language catalog.
    /// - Parameter explicitOptions: Explicit language choices shown in Settings.
    public init(explicitOptions: [AutoNamingLanguageOption] = Self.defaultExplicitOptions) {
        self.explicitOptions = explicitOptions
    }

    /// The built-in explicit choices. The `auto` setting can still resolve any
    /// system BCP-47 language tag, and cmux.json may store any resolvable tag.
    public static let defaultExplicitOptions: [AutoNamingLanguageOption] = [
        .init(slug: "en", bcp47Tag: "en", promptName: "English"),
        .init(slug: "ja", bcp47Tag: "ja", promptName: "Japanese"),
    ]

    /// Finds an explicit option by its stored slug.
    /// - Parameter slug: Stored setting value.
    /// - Returns: The matching explicit option, if any.
    public func option(forSlug slug: String) -> AutoNamingLanguageOption? {
        explicitOptions.first { $0.slug == slug }
    }
}
