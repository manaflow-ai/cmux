import Foundation

/// Repository for the close-tab warning settings, persisted in
/// `UserDefaults` under the catalog's `app.warnBeforeClosingTab`,
/// `app.warnBeforeClosingTabXButton`, and `app.hideTabCloseButton` keys.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every reader is
/// synchronous code that cannot await (close-shortcut handling, tab chrome
/// layout), the struct holds no mutable state, and `UserDefaults` is
/// documented thread-safe, so there is nothing for an actor to protect.
public struct CloseTabWarningStore: CloseTabWarningReading {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var warnsBeforeClosingTab: Bool {
        keys.warnBeforeClosingTab.value(in: defaults)
    }

    public var warnsBeforeClosingTabXButton: Bool {
        keys.warnBeforeClosingTabXButton.value(in: defaults)
    }

    public var hidesTabCloseButton: Bool {
        keys.hideTabCloseButton.value(in: defaults)
    }

    /// Enables or disables the close-shortcut warning.
    public func setWarnsBeforeClosingTab(_ isEnabled: Bool) {
        keys.warnBeforeClosingTab.set(isEnabled, in: defaults)
    }
}
