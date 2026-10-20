import Foundation

/// The density feedback and refusal texts (Handlers.xcstrings, 21 languages).
enum DensityStrings {
    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Handlers", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ argument: String) -> String {
        String(format: text(key, value), argument)
    }

    /// Choosing the density already in use.
    static func alreadyUsing(_ name: String) -> String { format("density.alreadyUsing", "Density is already %@", name) }
    /// A new custom density was made and is in use.
    static func created(_ name: String) -> String { format("density.created", "Made density “%@” and switched to it", name) }
    /// No density has the id.
    static func unknown(_ id: String) -> String { format("density.unknown", "No density named “%@”", id) }
    /// A new density needs a name.
    static var nameRequired: String { text("density.nameRequired", "Name the new density") }
    /// The custom density row's Return command.
    static var use: String { text("density.use", "Use Density") }
    /// The palette's mark on the density in use.
    static var current: String { text("density.current", "current") }
}
