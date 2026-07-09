internal import Foundation

/// The `workspace.set_auto_title` probe snapshot (the legacy `probe == true`
/// branch's data), resolved app-side so the coordinator can shape the identical
/// payload.
///
/// The legacy body read the auto-naming enabled flag and the summarizer agent
/// slug from Settings, then — only when the request carried a `workspace_id`
/// AND a TabManager resolved — also reported whether the user owns that
/// workspace's title, so naming engines can skip the LLM call for workspaces the
/// user renamed.
public struct ControlWorkspaceAutoTitleProbe: Sendable, Equatable {
    /// Whether workspace auto-naming is enabled in Settings (the `enabled` key).
    public var enabled: Bool

    /// The summarizer agent slug to report (the `summarizer_agent` key), already
    /// mapped to `nil` when it equals the auto sentinel (so the coordinator
    /// encodes JSON `null`).
    public var summarizerAgentSlug: String?

    /// Whether to include the `workspace_user_owned` key at all (true only when
    /// the request carried a `workspace_id` and a TabManager resolved, matching
    /// the legacy `if let workspaceId …, let tabManager …` guard).
    public var includeUserOwned: Bool

    /// The `workspace_user_owned` value when `includeUserOwned` is true: true/
    /// false when the workspace resolved, `nil` (JSON `null`) when it did not or
    /// its title is not user-owned.
    public var userOwned: Bool?

    /// Creates a probe snapshot.
    ///
    /// - Parameters:
    ///   - enabled: Whether auto-naming is enabled.
    ///   - summarizerAgentSlug: The summarizer slug to report (nil → JSON null).
    ///   - includeUserOwned: Whether to include `workspace_user_owned`.
    ///   - userOwned: The user-owned value (when included).
    public init(
        enabled: Bool,
        summarizerAgentSlug: String?,
        includeUserOwned: Bool,
        userOwned: Bool?
    ) {
        self.enabled = enabled
        self.summarizerAgentSlug = summarizerAgentSlug
        self.includeUserOwned = includeUserOwned
        self.userOwned = userOwned
    }
}
