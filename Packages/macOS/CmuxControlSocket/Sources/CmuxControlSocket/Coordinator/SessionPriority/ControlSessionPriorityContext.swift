public import Foundation

/// One workspace's session priority, as wire strings.
public struct ControlSessionPrioritySnapshot: Sendable, Equatable {
    /// One Claude pane; every value is already a wire string.
    public struct Pane: Sendable, Equatable {
        public var surfaceId: UUID
        public var sessionId: String?
        public var currentEffort: String?
        /// `up_to_date`, `applying`, `held`, `not_applied` or `manual`.
        public var state: String
        /// The hold reason or refusal (e.g. `held.draft`), or the manual signal.
        public var detail: String?

        public init(
            surfaceId: UUID,
            sessionId: String?,
            currentEffort: String?,
            state: String,
            detail: String?
        ) {
            self.surfaceId = surfaceId
            self.sessionId = sessionId
            self.currentEffort = currentEffort
            self.state = state
            self.detail = detail
        }
    }

    public var workspaceId: UUID
    public var enabled: Bool
    public var tier: String?
    public var difficulty: String
    public var difficultySource: String
    public var difficultyOverride: String?
    public var difficultyAuto: String?
    public var manual: Bool
    public var manualSignal: String?
    public var targetEffort: String?
    public var targetModel: String?
    public var panes: [Pane]

    public init(
        workspaceId: UUID,
        enabled: Bool,
        tier: String?,
        difficulty: String,
        difficultySource: String,
        difficultyOverride: String?,
        difficultyAuto: String?,
        manual: Bool,
        manualSignal: String?,
        targetEffort: String?,
        targetModel: String?,
        panes: [Pane]
    ) {
        self.workspaceId = workspaceId
        self.enabled = enabled
        self.tier = tier
        self.difficulty = difficulty
        self.difficultySource = difficultySource
        self.difficultyOverride = difficultyOverride
        self.difficultyAuto = difficultyAuto
        self.manual = manual
        self.manualSignal = manualSignal
        self.targetEffort = targetEffort
        self.targetModel = targetModel
        self.panes = panes
    }
}

/// The outcome of reading or mutating one workspace's session priority.
public enum ControlSessionPriorityResolution: Sendable {
    case tabManagerUnavailable
    case notFound
    /// The difficulty raw value is not `easy`, `normal` or `hard`.
    case invalidDifficulty(String)
    case resolved(windowID: UUID?, snapshot: ControlSessionPrioritySnapshot)
}

/// The cheap answer to `session_priority.set` with `probe: true`, so a hook
/// can decide whether to assess difficulty before paying for it.
public struct ControlSessionPriorityProbe: Sendable {
    public var enabled: Bool
    public var workspaceId: UUID
    public var manual: Bool
    public var overridePresent: Bool

    public init(enabled: Bool, workspaceId: UUID, manual: Bool, overridePresent: Bool) {
        self.enabled = enabled
        self.workspaceId = workspaceId
        self.manual = manual
        self.overridePresent = overridePresent
    }
}

/// The outcome of `session_priority.status`.
public enum ControlSessionPriorityStatusResolution: Sendable {
    case tabManagerUnavailable
    /// `workspaces` are in effective rank order.
    case resolved(windowID: UUID?, enabled: Bool, urgentCount: Int, workspaces: [ControlSessionPrioritySnapshot])
}

/// The session-priority slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella).
///
/// The app target resolves the workspace like the workspace-todo domain
/// (explicit id workspace-owner-first, else the routed window's selected
/// workspace). Difficulty, tier, state and signals cross as wire strings; no
/// app types cross. Relay-denied: none of these methods is allowlisted.
@MainActor
public protocol ControlSessionPriorityContext: AnyObject {
    /// Reads one workspace's session priority for `session_priority.get`.
    func controlSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityResolution

    /// Applies `session_priority.set`.
    ///
    /// - Parameters:
    ///   - difficultyRaw: `easy`, `normal` or `hard` to set, else `nil`.
    ///   - clearDifficulty: Whether to clear the user override (`difficulty: auto`).
    ///   - manual: The manual flag to set, if any.
    ///   - source: `user` (override and manual) or `auto` (the auto value only).
    func controlSetSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        difficultyRaw: String?,
        clearDifficulty: Bool,
        manual: Bool?,
        source: String
    ) -> ControlSessionPriorityResolution

    /// Answers `session_priority.set` with `probe: true`; `nil` when the
    /// workspace cannot be resolved.
    func controlProbeSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityProbe?

    /// Reads the routed window's ranked workspaces for `session_priority.status`.
    func controlSessionPriorityStatus(
        routing: ControlRoutingSelectors
    ) -> ControlSessionPriorityStatusResolution
}
