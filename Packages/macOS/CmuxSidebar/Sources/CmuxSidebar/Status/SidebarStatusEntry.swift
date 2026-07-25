public import Foundation

/// One keyed status row shown under a workspace in the sidebar
/// (e.g. an agent status line), as reported over the control socket.
public struct SidebarStatusEntry: Equatable, Sendable {
    /// Stable key identifying the row (last write per key wins).
    public let key: String
    /// The displayed status text.
    public let value: String
    /// Optional SF Symbol name shown before the text.
    public let icon: String?
    /// Optional hex color for the row.
    public let color: String?
    /// Optional URL the row opens when clicked.
    public let url: URL?
    /// Sort priority (higher sorts first).
    public let priority: Int
    /// How `value` is rendered.
    public let format: SidebarMetadataFormat
    /// When the entry was reported.
    public let timestamp: Date
    /// Hook-captured agent event time used to order detached deliveries.
    public let agentEventTime: TimeInterval?
    /// Pane whose detached hook stream owns this agent status row.
    public let agentOwnerPanelID: UUID?

    /// Creates a status row (defaults mirror the legacy initializer).
    public init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date(),
        agentEventTime: TimeInterval? = nil,
        agentOwnerPanelID: UUID? = nil
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
        self.agentEventTime = agentEventTime
        self.agentOwnerPanelID = agentOwnerPanelID
    }

    /// Determines whether an incoming status row should replace the current row.
    ///
    /// Agent rows use `agentEventTime` to order detached hook deliveries, so an
    /// older agent event cannot overwrite a newer status even if it arrives later.
    public static func replacementDecision(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        agentEventTime: TimeInterval? = nil,
        agentOwnerPanelID: UUID? = nil
    ) -> SidebarStatusEntryReplacementDecision {
        guard let current else { return .replace }
        let payloadMatches = current.key == key &&
            current.value == value &&
            current.icon == icon &&
            current.color == color &&
            current.url == url &&
            current.priority == priority &&
            current.format == format &&
            current.agentOwnerPanelID == agentOwnerPanelID
        if current.agentOwnerPanelID == agentOwnerPanelID,
           let currentAgentEventTime = current.agentEventTime {
            guard let agentEventTime else { return .stale }
            if agentEventTime < currentAgentEventTime {
                return .stale
            }
        }
        if payloadMatches, current.agentEventTime == agentEventTime {
            return .unchanged
        }
        return .replace
    }

    /// Returns true only when `replacementDecision` chooses `.replace`.
    public static func shouldReplace(
        current: SidebarStatusEntry?,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: SidebarMetadataFormat,
        agentEventTime: TimeInterval? = nil,
        agentOwnerPanelID: UUID? = nil
    ) -> Bool {
        replacementDecision(
            current: current,
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format,
            agentEventTime: agentEventTime,
            agentOwnerPanelID: agentOwnerPanelID
        ) == .replace
    }
}

/// Replacement result for a sidebar status row mutation.
public enum SidebarStatusEntryReplacementDecision: Equatable, Sendable {
    /// Apply the incoming row.
    case replace
    /// Drop the mutation because it is identical to the current row.
    case unchanged
    /// Drop the mutation because it is older than the current agent row.
    case stale
}
