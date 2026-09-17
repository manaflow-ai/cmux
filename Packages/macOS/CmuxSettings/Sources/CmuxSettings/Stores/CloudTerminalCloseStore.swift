import Foundation

/// Repository for the cloud terminal close action, persisted in `UserDefaults`
/// under the catalog's `app.closeCloudTerminal` key.
///
/// Isolation: a stateless `Sendable` struct, not an actor — the close gate
/// reads synchronously on the main thread, the struct holds no mutable state,
/// and `UserDefaults` is documented thread-safe.
public struct CloudTerminalCloseStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The effective close action; an unrecognized stored value reads as the default (`ask`).
    public var action: CloudTerminalCloseAction {
        keys.closeCloudTerminal.value(in: defaults)
    }

    /// Persists `action` (the prompt's "Remember my choice", or the Settings picker).
    public func setAction(_ action: CloudTerminalCloseAction) {
        keys.closeCloudTerminal.set(action, in: defaults)
    }
}
