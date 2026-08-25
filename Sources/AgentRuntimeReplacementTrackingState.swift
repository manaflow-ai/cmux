import CMUXAgentLaunch
import Foundation

/// Shared ordering and compatibility rules for immutable hook-session generations.
enum AgentRuntimeGenerationPolicy {
    static func isValid(_ generation: TimeInterval?) -> Bool {
        generation.map { $0.isFinite && $0 > 0 } ?? true
    }

    /// Legacy metadata has no generation and may be upgraded in place. Once
    /// both sides carry generations, they identify the same runtime only when
    /// the immutable session-start values are equal.
    static func identifiesSameRuntime(
        _ lhs: TimeInterval?,
        _ rhs: TimeInterval?
    ) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    /// A generated runtime cannot be torn down by a generation-less request.
    /// A legacy stored runtime still accepts a generated request during a
    /// mixed-version upgrade because it has no stronger identity to compare.
    static func authorizesCleanup(
        stored: TimeInterval?,
        incoming: TimeInterval?
    ) -> Bool {
        switch (stored, incoming) {
        case let (stored?, incoming?):
            stored == incoming
        case (nil, _):
            true
        case (_?, nil):
            false
        }
    }

    /// Ordinary runtime mutations require the exact established generation.
    /// Establishment is a separate operation so a status, lifecycle, or
    /// notification cannot promote itself to a newer runtime.
    static func authorizesMutation(
        stored: TimeInterval?,
        incoming: TimeInterval?
    ) -> Bool {
        stored == incoming
    }
}

/// Exact runtime authority retained independently of resume-binding metadata.
struct AgentRuntimeGenerationAuthority: Equatable {
    let sessionKey: AgentRuntimeSessionKey
    let generation: TimeInterval?
}

/// Transient agent-runtime delivery guards that follow a live panel across owner moves.
struct AgentRuntimeReplacementTrackingState {
    let supersededBindings: [SurfaceResumeBindingSnapshot]
    let retiredBindings: [SurfaceResumeBindingSnapshot]
    let pendingReplacementBinding: SurfaceResumeBindingSnapshot?
    let currentAuthority: AgentRuntimeGenerationAuthority?
    let retiredAuthorities: [AgentRuntimeGenerationAuthority]
    /// Per-status-key high-water marks. Hook stores mint generations
    /// independently per agent, so one agent's sequence must not block a
    /// different agent from becoming the panel's current runtime.
    let generationHighWaterMarksByStatusKey: [String: TimeInterval]
}
