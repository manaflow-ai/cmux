import Foundation

/// A fresh, empty `UserDefaults` suite for one test, so tests never touch
/// `UserDefaults.standard`.
///
/// - Returns: `defaults` for the test's own reads and writes, and `open`, the
///   `@Sendable` provider the `Sendable` stores take (a `UserDefaults` object
///   is not `Sendable`, a suite name is).
func makeTestDefaultsSuite(_ prefix: String) -> (defaults: UserDefaults, open: @Sendable () -> UserDefaults) {
    let suite = "\(prefix).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, { UserDefaults(suiteName: suite)! })
}
