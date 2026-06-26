import Foundation

/// A mutable target that ``SettingsFileProjectionEngine`` writes managed
/// `UserDefaults` values into, one key at a time.
///
/// Inverting the write behind this protocol lets the projection engine project
/// parsed settings sections without depending on the app-side snapshot type that
/// accumulates them: the snapshot conforms and stores each projected value under
/// its key, replacing any prior value for that key.
public protocol ManagedSettingsProjecting {
    /// Records `value` as the managed default for `key`, replacing any prior
    /// value stored for that key.
    mutating func projectManagedDefault(_ value: ManagedSettingsValue, forKey key: String)
}
