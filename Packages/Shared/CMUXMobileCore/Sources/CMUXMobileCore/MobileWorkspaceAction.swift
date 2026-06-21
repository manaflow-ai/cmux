import Foundation

/// The `workspace.action` sub-actions the mobile data plane is allowed to invoke.
///
/// The Mac exposes the full `workspace.action` verb to the local automation
/// socket, but the paired phone may only run a safe subset: pin/unpin, rename,
/// and the read-state toggles. The other sub-actions reorder the global sidebar
/// or destroy sibling workspaces, so they stay on the Mac and are rejected when
/// they arrive over the mobile data plane.
///
/// This enum is the single source of truth for that allow-list. It is a pure
/// value type so the gate can be exhaustively tested without a live connection,
/// and the mobile data-plane RPC dispatcher consults it so the gate and the
/// handler can never disagree on which action runs.
public enum MobileWorkspaceAction: String, CaseIterable, Sendable {
    /// Pin the workspace to the top of the sidebar.
    case pin
    /// Unpin a pinned workspace.
    case unpin
    /// Rename the workspace.
    case rename
    /// Mark the workspace read.
    case markRead = "mark_read"
    /// Mark the workspace unread.
    case markUnread = "mark_unread"

    /// Classifies a raw `action` param value as a mobile-allowed action.
    ///
    /// The raw value is normalized exactly as the v2 action-key normalizer does
    /// (trim surrounding whitespace, lowercase, then map `-` to `_`) so this gate
    /// and the handler can never disagree on which action runs. A `nil`, empty, or
    /// non-allowed action returns `nil`.
    ///
    /// - Parameter rawAction: The raw `action` param value, or `nil`.
    /// - Returns: The matching ``MobileWorkspaceAction``, or `nil` when the action
    ///   is missing or not mobile-allowed.
    public init?(rawMobileAction rawAction: String?) {
        guard let trimmed = rawAction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "_")
        guard let action = MobileWorkspaceAction(rawValue: normalized) else {
            return nil
        }
        self = action
    }

    /// Whether the given raw `action` value is one the mobile data plane may run.
    ///
    /// - Parameter rawAction: The raw `action` param value, or `nil`.
    /// - Returns: `true` when the normalized action is mobile-allowed.
    public static func isMobileAllowed(_ rawAction: String?) -> Bool {
        MobileWorkspaceAction(rawMobileAction: rawAction) != nil
    }
}
