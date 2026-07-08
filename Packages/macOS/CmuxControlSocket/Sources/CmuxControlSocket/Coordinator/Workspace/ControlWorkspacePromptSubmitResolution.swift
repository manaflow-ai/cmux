public import Foundation

/// The outcome of `workspace.prompt_submit`, after the coordinator has validated
/// `workspace_id` and the message-param types and selected the message text.
public enum ControlWorkspacePromptSubmitResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspace was not found (legacy `not_found` / "Workspace not found",
    /// data carries only `workspace_id`).
    case notFound
    /// The prompt was submitted. Carries the owning window id (may be absent),
    /// whether iMessage mode is enabled, the submit outcome, and the latest
    /// submitted message preview (may be absent).
    case resolved(
        windowID: UUID?,
        iMessageModeEnabled: Bool,
        messageRecorded: Bool,
        reordered: Bool,
        index: Int,
        messagePreview: String?
    )
}
