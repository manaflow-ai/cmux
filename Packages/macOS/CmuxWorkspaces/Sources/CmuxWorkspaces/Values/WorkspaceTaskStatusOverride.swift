/// A manual todo-status override with anti-rot auto-clear: the override
/// records the status that was inferred at the moment it was set. As soon as
/// the live inferred status moves away from that recording, the override is
/// considered expired, effective status falls back to inferred, and the
/// stored override should be cleared.
public struct WorkspaceTaskStatusOverride: Codable, Hashable, Sendable {
    /// The manually chosen status.
    public var status: WorkspaceTaskStatus
    /// The inferred status at the moment the override was set.
    public var inferredAtOverride: WorkspaceTaskStatus

    /// Creates an override.
    public init(status: WorkspaceTaskStatus, inferredAtOverride: WorkspaceTaskStatus) {
        self.status = status
        self.inferredAtOverride = inferredAtOverride
    }

    /// The result of resolving an optional override against the current
    /// inferred status.
    public struct Resolution: Equatable, Sendable {
        /// The status to display.
        public let effective: WorkspaceTaskStatus
        /// Whether the stored override expired and should be cleared.
        public let shouldClearOverride: Bool

        /// Creates a resolution.
        public init(effective: WorkspaceTaskStatus, shouldClearOverride: Bool) {
            self.effective = effective
            self.shouldClearOverride = shouldClearOverride
        }
    }

    /// Resolves the effective status: no override → inferred; an override
    /// whose recorded inference still matches the current inference → the
    /// override's status; an override whose recorded inference no longer
    /// matches → inferred, flagged for clearing.
    ///
    /// - Parameters:
    ///   - override: The stored override, if any.
    ///   - inferred: The currently inferred status.
    /// - Returns: The effective status and whether to clear the override.
    public static func effectiveStatus(
        override: WorkspaceTaskStatusOverride?,
        inferred: WorkspaceTaskStatus
    ) -> Resolution {
        guard let override else {
            return Resolution(effective: inferred, shouldClearOverride: false)
        }
        guard override.inferredAtOverride == inferred else {
            return Resolution(effective: inferred, shouldClearOverride: true)
        }
        return Resolution(effective: override.status, shouldClearOverride: false)
    }
}
