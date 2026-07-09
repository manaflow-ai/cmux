public import Foundation

/// `UserDefaults`-backed repository tracking which limited-access extension
/// banners the user chose to keep dismissed, keyed by a per-extension choice key.
public struct CMUXSidebarExtensionLimitedChoiceStore {
    private static let defaultsKey = "cmuxExtensionSidebar.limitedChoices.v1"

    /// Defaults store the kept choices are read from and written to.
    public var defaults: UserDefaults

    /// Creates a choice store backed by the given defaults (the standard suite by
    /// default).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The set of choice keys the user has elected to keep.
    public func choices() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Records that the user kept the choice for the given key.
    public func insert(_ key: String) {
        var choices = choices()
        choices.insert(key)
        save(choices)
    }

    /// Removes a previously kept choice for the given key.
    public func remove(_ key: String) {
        var choices = choices()
        choices.remove(key)
        save(choices)
    }

    private func save(_ choices: Set<String>) {
        defaults.set(choices.sorted(), forKey: Self.defaultsKey)
    }
}
