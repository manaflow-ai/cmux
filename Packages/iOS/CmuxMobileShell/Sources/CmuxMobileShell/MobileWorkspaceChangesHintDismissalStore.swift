public import Foundation

/// Persists one-time workspace-changes hint dismissal in injected user defaults.
public struct MobileWorkspaceChangesHintDismissalStore {
    private static let keyPrefix = "cmux.mobile.workspaceChangesHint.seen."
    private let defaults: UserDefaults

    /// Creates a dismissal store backed by the supplied defaults domain.
    ///
    /// - Parameter defaults: The defaults domain; production uses `UserDefaults.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns whether the hint has already been seen for a workspace.
    ///
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: `true` after explicit dismissal or the first sheet opening.
    public func isDismissed(workspaceID: String) -> Bool {
        defaults.bool(forKey: Self.key(for: workspaceID))
    }

    /// Permanently marks the hint as seen for a workspace.
    ///
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func dismiss(workspaceID: String) {
        defaults.set(true, forKey: Self.key(for: workspaceID))
    }

    private static func key(for workspaceID: String) -> String {
        keyPrefix + workspaceID
    }
}
