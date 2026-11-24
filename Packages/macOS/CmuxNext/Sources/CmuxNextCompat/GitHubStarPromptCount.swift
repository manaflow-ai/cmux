public import Foundation

/// The GitHub star ask's count of prompts the person sent (t3code's rule; CmuxNextUpdater's
/// GitHubStarPrompt reads it). Separate keys, so a count written by another window never undoes a dismissal.
public nonisolated struct GitHubStarPromptCount {
    public nonisolated init() {}
    public static let promptsBeforeAsking = 5
    public static let sentKey = "cmux.githubStarPrompt.sent"
    public static let dismissedKey = "cmux.githubStarPrompt.dismissed"

    /// Counts one sent prompt (stops counting once dismissed).
    public static func countPrompt(in defaults: UserDefaults) {
        if defaults.bool(forKey: dismissedKey) { return }
        defaults.set(defaults.integer(forKey: sentKey) + 1, forKey: sentKey)
    }

    /// More than five sent and never dismissed.
    public static func wanted(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: dismissedKey) && defaults.integer(forKey: sentKey) > promptsBeforeAsking
    }

    public static func dismiss(in defaults: UserDefaults) { defaults.set(true, forKey: dismissedKey) }
}
