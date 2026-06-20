public import Foundation

/// One tag row of a `system.top` / `system.memory` workspace (the legacy
/// per-`tags` dictionary of `v2TopTagNodes`, minus the coordinator-minted
/// id/ref and the process-annotation fields the nonisolated `system.top`
/// pipeline adds afterward).
///
/// The coordinator mints the tag `id` / `ref` from ``workspaceID`` and ``key``
/// (`"<workspaceID>:tag:<escapedKey>"` and
/// `"workspace:<workspaceID>:tag:<escapedKey>"`), so the percent-escaping has a
/// single source of truth in the package.
public struct ControlSystemTopTagNode: Sendable, Equatable {
    /// The owning workspace's identifier (drives the minted id/ref).
    public let workspaceID: UUID
    /// The tag's index in the emitted tag list.
    public let index: Int
    /// The status-entry key (drives the minted id/ref and the `key` field).
    public let key: String
    /// The status-entry value (empty for the agent-PID-only fallback tags).
    public let value: String
    /// The status icon, if any.
    public let icon: String?
    /// The status color, if any.
    public let color: String?
    /// The status URL string, if any.
    public let url: String?
    /// The status priority (`0` for the agent-PID-only fallback tags).
    public let priority: Int
    /// The status format's raw value (`"plain"` for the fallback tags).
    public let formatRawValue: String
    /// Whether the tag is a display-ordered status entry (`true`) or an
    /// agent-PID-only fallback (`false`).
    public let isVisible: Bool
    /// The agent process identifier, if the workspace reported a positive one.
    public let pid: Int?

    /// Creates a tag node.
    ///
    /// - Parameters:
    ///   - workspaceID: The owning workspace's identifier.
    ///   - index: The tag's index in the emitted list.
    ///   - key: The status-entry key.
    ///   - value: The status-entry value.
    ///   - icon: The status icon, if any.
    ///   - color: The status color, if any.
    ///   - url: The status URL string, if any.
    ///   - priority: The status priority.
    ///   - formatRawValue: The status format's raw value.
    ///   - isVisible: Whether the tag is a display-ordered status entry.
    ///   - pid: The agent process identifier, if any.
    public init(
        workspaceID: UUID,
        index: Int,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: String?,
        priority: Int,
        formatRawValue: String,
        isVisible: Bool,
        pid: Int?
    ) {
        self.workspaceID = workspaceID
        self.index = index
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.formatRawValue = formatRawValue
        self.isVisible = isVisible
        self.pid = pid
    }
}
