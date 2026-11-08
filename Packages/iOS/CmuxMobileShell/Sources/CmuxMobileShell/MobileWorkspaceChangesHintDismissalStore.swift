public import Foundation

/// Persists one-time workspace-changes hint dismissal in injected user defaults.
///
/// Seen workspace IDs live in one capped FIFO array key so ephemeral agent
/// workspaces cannot grow the defaults domain without bound; evicting an old
/// ID merely lets the one-time hint reappear for that workspace.
public struct MobileWorkspaceChangesHintDismissalStore {
    private static let seenIDsKey = "cmux.mobile.workspaceChangesHint.seenIDs"
    private static let maximumStoredIDCount = 256
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
        storedIDs().contains(workspaceID)
    }

    /// Marks the hint as seen for a workspace, evicting the oldest stored ID
    /// beyond the cap.
    ///
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func dismiss(workspaceID: String) {
        var ids = storedIDs()
        guard !ids.contains(workspaceID) else { return }
        ids.append(workspaceID)
        if ids.count > Self.maximumStoredIDCount {
            ids.removeFirst(ids.count - Self.maximumStoredIDCount)
        }
        defaults.set(ids, forKey: Self.seenIDsKey)
    }

    private func storedIDs() -> [String] {
        defaults.stringArray(forKey: Self.seenIDsKey) ?? []
    }
}
