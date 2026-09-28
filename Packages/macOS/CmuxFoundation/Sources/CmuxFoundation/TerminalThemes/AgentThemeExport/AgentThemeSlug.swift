import Foundation

/// The `cmux-` prefixed file slug an exported agent theme is saved under.
///
/// Every exported file name starts with `cmux-`, so `--write` only ever
/// replaces files cmux created and never a theme the user wrote by hand.
///
/// ```swift
/// AgentThemeSlug(name: "Catppuccin Mocha").value // "cmux-catppuccin-mocha"
/// ```
public struct AgentThemeSlug: Equatable, Sendable {
    /// The prefix every exported theme file carries.
    public static let prefix = "cmux-"

    /// The slug, always starting with ``prefix``: lowercase ASCII letters,
    /// digits and single hyphens.
    public let value: String

    /// Derives the slug from a theme or user-chosen name.
    ///
    /// Runs of anything other than ASCII letters and digits become one hyphen,
    /// so the slug is always a plain file name. A name that already starts with
    /// `cmux-` is not prefixed twice.
    /// - Parameter name: A Ghostty theme name or a `--name` value.
    /// - Returns: `nil` when the name has no ASCII letters or digits.
    public init?(name: String) {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isAlphanumeric = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
            if isAlphanumeric {
                if pendingHyphen, !slug.isEmpty { slug += "-" }
                slug.unicodeScalars.append(scalar)
                pendingHyphen = false
            } else {
                pendingHyphen = true
            }
        }
        guard !slug.isEmpty, slug != "cmux" else { return nil }
        value = slug.hasPrefix(Self.prefix) ? slug : Self.prefix + slug
    }

    /// The theme file name, `<slug>.json`.
    public var fileName: String {
        value + ".json"
    }
}
