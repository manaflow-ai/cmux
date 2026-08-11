public import CmuxAgentReplica
import Foundation

/// Records which truth channels have contributed to a session.
public struct DetectionEvidence: Hashable, Sendable {
    /// Whether process observation contributed.
    public var hasProcessObservation: Bool
    /// Whether wrapper launch evidence contributed.
    public var hasWrapperLaunch: Bool
    /// Whether hook events contributed.
    public var hasHookEvents: Bool
    /// Whether transcript corroboration contributed.
    public var hasTranscriptCorroboration: Bool
    /// The process identity currently bound to the session.
    public var processIdentity: ProcessIdentity?
    /// The transcript path currently associated with the session.
    public var transcriptPath: String?
    /// Capability and degradation reasons attached to the evidence.
    public var reasons: Set<CapabilityReason>

    /// Creates evidence with optional channel contributions.
    /// - Parameters:
    ///   - hasProcessObservation: Whether process observation contributed.
    ///   - hasWrapperLaunch: Whether wrapper launch evidence contributed.
    ///   - hasHookEvents: Whether hook events contributed.
    ///   - hasTranscriptCorroboration: Whether transcript corroboration contributed.
    ///   - processIdentity: The bound process identity.
    ///   - transcriptPath: The transcript path.
    ///   - reasons: Capability and degradation reasons.
    public init(
        hasProcessObservation: Bool = false,
        hasWrapperLaunch: Bool = false,
        hasHookEvents: Bool = false,
        hasTranscriptCorroboration: Bool = false,
        processIdentity: ProcessIdentity? = nil,
        transcriptPath: String? = nil,
        reasons: Set<CapabilityReason> = []
    ) {
        self.hasProcessObservation = hasProcessObservation
        self.hasWrapperLaunch = hasWrapperLaunch
        self.hasHookEvents = hasHookEvents
        self.hasTranscriptCorroboration = hasTranscriptCorroboration
        self.processIdentity = processIdentity
        self.transcriptPath = transcriptPath
        self.reasons = reasons
    }

    /// The detection tier implied by the current evidence.
    public var tier: DetectionTier {
        if reasons.contains(.launchedWhileSocketDown) || reasons.contains(.evidenceConflict) || reasons.contains(.transcriptNotReadable) {
            return .degraded
        }
        if hasWrapperLaunch {
            return .wrapped
        }
        if hasHookEvents {
            return .hooked
        }
        return .observed
    }
}
