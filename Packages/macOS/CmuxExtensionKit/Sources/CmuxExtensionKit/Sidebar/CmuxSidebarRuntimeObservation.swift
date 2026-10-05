import Foundation

/// Native agent evidence associated with one surface, without transcript contents.
public struct CmuxSidebarRuntimeObservation: Codable, Equatable, Sendable {
    /// Observed agent lifecycle; uncertainty is represented explicitly.
    public var lifecycle: CmuxSidebarAgentLifecycle
    /// Time of the evidence, or `nil` when the host cannot establish freshness.
    public var observedAt: Date?
    /// Native source that established the observation.
    public var provenance: CmuxSidebarRuntimeProvenance
    /// Stable agent-session identifier when known.
    public var sessionID: String?
    /// Native agent/tool identifier when known.
    public var toolID: String?
    /// Host-assigned process generation used to distinguish a replacement process.
    public var processGeneration: UInt64?
    /// Exact session activity, independent of the legacy aggregate phase.
    public var activity: CmuxSidebarAgentActivity
    /// Structured activity reason, or nil when no reason was asserted.
    public var reason: CmuxSidebarRuntimeReason?
    /// Independently observed execution mode; planning alone never means working or waiting.
    public var mode: CmuxSidebarAgentMode
    /// Original producer time of the latest activity/reason transition.
    public var transitionedAt: Date?
    /// Original producer time of the latest independent mode observation.
    public var modeObservedAt: Date?
    /// Host time of the current verified process sample; it does not refresh event evidence.
    public var sampledAt: Date?
    /// Unresolved native user-action requests, independently of current activity.
    public var pendingUserActionCount: Int

    /// Creates an observation using only the evidence the host can establish.
    ///
    /// - Parameters:
    ///   - lifecycle: Observed lifecycle; absence of evidence defaults to unknown.
    ///   - observedAt: Evidence timestamp, not snapshot delivery time.
    ///   - provenance: Source of the evidence; unknown by default.
    ///   - sessionID: Stable agent-session identifier, if available.
    ///   - toolID: Native tool identifier, if available.
    ///   - processGeneration: Replacement-process generation, if available.
    ///   - activity: Exact semantic session activity; unknown without evidence.
    ///   - reason: Structured native reason for that activity.
    ///   - mode: Native plan or execution mode, independent of activity.
    ///   - transitionedAt: Original time of the latest activity/reason change.
    ///   - modeObservedAt: Original time of the latest mode observation.
    ///   - sampledAt: Current verified process sample time.
    ///   - pendingUserActionCount: Exact native requests; legacy observations default to zero.
    public init(
        lifecycle: CmuxSidebarAgentLifecycle = .unknown,
        observedAt: Date? = nil,
        provenance: CmuxSidebarRuntimeProvenance = .unknown,
        sessionID: String? = nil,
        toolID: String? = nil,
        processGeneration: UInt64? = nil,
        activity: CmuxSidebarAgentActivity = .unknown,
        reason: CmuxSidebarRuntimeReason? = nil,
        mode: CmuxSidebarAgentMode = .unknown,
        transitionedAt: Date? = nil,
        modeObservedAt: Date? = nil,
        sampledAt: Date? = nil,
        pendingUserActionCount: Int = 0
    ) {
        self.lifecycle = lifecycle
        self.observedAt = observedAt
        self.provenance = provenance
        self.sessionID = sessionID
        self.toolID = toolID
        self.processGeneration = processGeneration
        self.activity = activity
        self.reason = reason
        self.mode = mode
        self.transitionedAt = transitionedAt
        self.modeObservedAt = modeObservedAt
        self.sampledAt = sampledAt
        self.pendingUserActionCount = max(0, pendingUserActionCount)
    }

    /// Decodes legacy observations without inventing rich session evidence.
    /// - Parameter decoder: The wire decoder.
    /// - Throws: A decoding error for malformed fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifecycle = try container.decode(CmuxSidebarAgentLifecycle.self, forKey: .lifecycle)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        provenance = try container.decode(CmuxSidebarRuntimeProvenance.self, forKey: .provenance)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        toolID = try container.decodeIfPresent(String.self, forKey: .toolID)
        processGeneration = try container.decodeIfPresent(UInt64.self, forKey: .processGeneration)
        activity = try container.decodeIfPresent(CmuxSidebarAgentActivity.self, forKey: .activity) ?? .unknown
        reason = try container.decodeIfPresent(CmuxSidebarRuntimeReason.self, forKey: .reason)
        mode = try container.decodeIfPresent(CmuxSidebarAgentMode.self, forKey: .mode) ?? .unknown
        transitionedAt = try container.decodeIfPresent(Date.self, forKey: .transitionedAt)
        modeObservedAt = try container.decodeIfPresent(Date.self, forKey: .modeObservedAt)
        sampledAt = try container.decodeIfPresent(Date.self, forKey: .sampledAt)
        pendingUserActionCount = max(0, try container.decodeIfPresent(Int.self, forKey: .pendingUserActionCount) ?? 0)
    }
}
