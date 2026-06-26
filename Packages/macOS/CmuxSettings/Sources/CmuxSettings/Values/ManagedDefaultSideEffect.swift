import Foundation

/// A single managed-default-changed descriptor: which `UserDefaults` key a
/// managed default mutated, the source that drove the change, and whether the
/// appearance change should also synchronize the terminal theme.
///
/// The store batches these in `ManagedDefaultBatchSideEffects` and replays them
/// after a managed-defaults apply, so each key's downstream notification and
/// applier runs exactly once with the right context.
public struct ManagedDefaultSideEffect: Sendable {
    /// The `UserDefaults` key whose managed value changed.
    public let defaultsKey: String

    /// The change source, forwarded to appearance appliers as the originating
    /// reason for the mutation.
    public let source: String

    /// Whether applying the appearance change should also synchronize the
    /// terminal theme (false during launch-time application).
    public let synchronizeAppearanceTerminalTheme: Bool

    /// Creates a managed-default-changed descriptor.
    public init(
        defaultsKey: String,
        source: String,
        synchronizeAppearanceTerminalTheme: Bool
    ) {
        self.defaultsKey = defaultsKey
        self.source = source
        self.synchronizeAppearanceTerminalTheme = synchronizeAppearanceTerminalTheme
    }
}
