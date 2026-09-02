import Foundation

/// Localized response strings supplied by the application to task-queue RPCs.
///
/// The control-socket package cannot resolve the executable's localization
/// catalog, so the composition root provides these already-localized values.
/// The defaults keep package-only test seams and staged owners functional until
/// they provide their own catalog-backed copy.
nonisolated public struct ControlWorkspaceTaskQueueStrings: Sendable, Equatable {
    /// Message for an unsupported status filter.
    public let invalidStatus: String
    /// Message used while the app's workspace registry is unavailable.
    public let unavailable: String
    /// Message for a missing queue-item selector.
    public let itemIDRequired: String
    /// Message for an unknown queue item.
    public let notFound: String
    /// Message when a row has no configured dispatch target.
    public let notDispatchable: String
    /// Message for a malformed target value.
    public let invalidTarget: String

    /// Creates the queue response strings.
    public init(
        invalidStatus: String = "status must be one of: pending, in-progress, completed",
        unavailable: String = "TabManager not available",
        itemIDRequired: String = "item_id is required",
        notFound: String = "Queue item not found",
        notDispatchable: String = "Queue item has no dispatch target",
        invalidTarget: String = "target must be an object, null, or omitted"
    ) {
        self.invalidStatus = invalidStatus
        self.unavailable = unavailable
        self.itemIDRequired = itemIDRequired
        self.notFound = notFound
        self.notDispatchable = notDispatchable
        self.invalidTarget = invalidTarget
    }
}
