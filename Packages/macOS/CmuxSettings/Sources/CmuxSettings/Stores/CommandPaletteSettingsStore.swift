import Foundation

/// Repository for the command-palette behavior settings, persisted in
/// `UserDefaults` under the catalog's `app.renameSelectsExistingName` and
/// `app.commandPaletteSearchesAllSurfaces` keys.
///
/// Isolation: a stateless `Sendable` struct, not an actor — readers are
/// synchronous (palette focus handling, socket debug commands), the struct
/// holds no mutable state, and `UserDefaults` is documented thread-safe.
public struct CommandPaletteSettingsStore: CommandPaletteSettingsReading {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var renameSelectsAllOnFocus: Bool {
        keys.renameSelectsExistingName.value(in: defaults)
    }

    public var switcherSearchesAllSurfaces: Bool {
        keys.commandPaletteSearchesAllSurfaces.value(in: defaults)
    }
}
