public import Foundation

/// Persists the one-time dismissal of the workspace simulator hint banner in
/// injected user defaults.
///
/// Global rather than per-workspace: the banner exists to teach that Mac
/// Simulator panes can be opened from the surfaces menu. Once the user has
/// dismissed it — or opened a simulator stream anywhere, which proves the
/// lesson landed — it never shows again on any workspace.
public struct MobileSimulatorStreamHintDismissalStore {
    private static let dismissedKey = "cmux.mobile.simulatorStreamHint.dismissed"
    private let defaults: UserDefaults

    /// Creates a dismissal store backed by the supplied defaults domain.
    ///
    /// - Parameter defaults: The defaults domain; production uses `UserDefaults.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the hint has been dismissed (explicitly or by opening a
    /// simulator stream).
    public var isDismissed: Bool {
        defaults.bool(forKey: Self.dismissedKey)
    }

    /// Marks the hint as permanently dismissed.
    public func markDismissed() {
        defaults.set(true, forKey: Self.dismissedKey)
    }
}
