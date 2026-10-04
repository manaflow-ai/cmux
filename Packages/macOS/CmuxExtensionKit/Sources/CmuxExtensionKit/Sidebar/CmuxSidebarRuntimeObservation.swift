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

    /// Creates an observation using only the evidence the host can establish.
    ///
    /// - Parameters:
    ///   - lifecycle: Observed lifecycle; absence of evidence defaults to unknown.
    ///   - observedAt: Evidence timestamp, not snapshot delivery time.
    ///   - provenance: Source of the evidence; unknown by default.
    ///   - sessionID: Stable agent-session identifier, if available.
    ///   - toolID: Native tool identifier, if available.
    ///   - processGeneration: Replacement-process generation, if available.
    public init(
        lifecycle: CmuxSidebarAgentLifecycle = .unknown,
        observedAt: Date? = nil,
        provenance: CmuxSidebarRuntimeProvenance = .unknown,
        sessionID: String? = nil,
        toolID: String? = nil,
        processGeneration: UInt64? = nil
    ) {
        self.lifecycle = lifecycle
        self.observedAt = observedAt
        self.provenance = provenance
        self.sessionID = sessionID
        self.toolID = toolID
        self.processGeneration = processGeneration
    }
}
