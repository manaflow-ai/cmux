import Foundation
import Observation

/// Per-panel agent-runtime, hibernation, and resume-binding state for one workspace window.
///
/// This `@MainActor @Observable` model owns the mutable per-panel dictionaries that back the
/// agent lifecycle / hibernation / resume-binding surface of the workspace window content model.
/// It is the lifted home of state that previously lived as stored properties on the app-target
/// `Workspace` god object; the workspace now holds one instance and forwards its former stored
/// properties to this model's dictionaries so external readers stay byte-identical.
///
/// The model is generic over the three Sendable payload value types the app target owns
/// (`Snapshot` = the restorable-agent snapshot, `Binding` = the surface resume binding,
/// `Lifecycle` = the per-status agent lifecycle state). It never imports those concrete types,
/// so the package graph stays acyclic: the workspace package depends on `CMUXAgentLaunch`, never
/// the reverse. App-coupled orchestration (process-id reaping, focus, hibernation entry/resume on
/// the live `TerminalPanel`, fingerprinting) stays in the app target and routes its storage
/// through this model.
///
/// Keying is by panel `UUID`. The model is `@MainActor` because every mutator and reader of this
/// state originates on the main actor (the workspace model and its UI), so co-locating the state
/// with its callers keeps the forwards plain property access with no bridging.
@MainActor
@Observable
public final class AgentHibernationLifecycleModel<Snapshot, Binding, Lifecycle>
where Snapshot: Sendable, Binding: Sendable, Lifecycle: Sendable {
    /// Resume-progression state for a restored agent snapshot once its panel is observed running
    /// or idle. Lifted verbatim from the former nested `Workspace.RestoredAgentResumeState`.
    public enum RestoredAgentResumeState: Equatable, Sendable {
        case manualResumeAvailable
        case awaitingAutoResumeCommand
        case autoResumeCommandRunning
        case observedAgentCommandRunning
    }

    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    public var agentPIDs: [String: pid_t] = [:]
    /// Panel that owns each agent status key, keyed by status key.
    public var agentPIDPanelIdsByKey: [String: UUID] = [:]
    /// Agent status keys owned by each panel, keyed by panel id.
    public var agentPIDKeysByPanelId: [UUID: Set<String>] = [:]
    /// Per-status agent lifecycle state for each panel, keyed by panel id then status key.
    public var agentLifecycleStatesByPanelId: [UUID: [String: Lifecycle]] = [:]
    /// Restored agent snapshot eligible for hibernation/resume, keyed by panel id.
    public var restoredAgentSnapshotsByPanelId: [UUID: Snapshot] = [:]
    /// Surface resume binding (startup input / checkpoint), keyed by panel id.
    public var surfaceResumeBindingsByPanelId: [UUID: Binding] = [:]
    /// Resume-progression state for a restored agent snapshot, keyed by panel id.
    public var restoredAgentResumeStatesByPanelId: [UUID: RestoredAgentResumeState] = [:]
    /// Fingerprints of snapshots invalidated for resume, keyed by panel id.
    public var invalidatedRestoredAgentFingerprintsByPanelId: [UUID: Int] = [:]

    public init() {}

    /// Resume-state assigned when a restored snapshot is first accepted for a panel, given whether
    /// that panel's shell is observed running a command.
    public func resumeStateForAcceptedSnapshot(
        isCommandRunning: Bool
    ) -> RestoredAgentResumeState {
        isCommandRunning ? .observedAgentCommandRunning : .manualResumeAvailable
    }

    /// Advances the resume-progression state for a panel as its shell activity transitions, and
    /// reports whether the snapshot should be invalidated. `isCommandRunning`/`isPromptIdle`
    /// encode the two observed shell transitions; when neither is set the call is a no-op.
    ///
    /// Mirrors the former `Workspace.updateRestoredAgentResumeState` switch exactly; the caller
    /// performs the actual invalidation (which has app-coupled side effects) when this returns true.
    @discardableResult
    public func advanceResumeState(
        panelId: UUID,
        isCommandRunning: Bool,
        isPromptIdle: Bool
    ) -> Bool {
        if isCommandRunning {
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.awaitingAutoResumeCommand):
                restoredAgentResumeStatesByPanelId[panelId] = .autoResumeCommandRunning
                return false
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                return false
            case .some(.manualResumeAvailable), nil:
                return true
            }
        } else if isPromptIdle {
            switch restoredAgentResumeStatesByPanelId[panelId] {
            case .some(.autoResumeCommandRunning), .some(.observedAgentCommandRunning):
                return true
            case .some(.awaitingAutoResumeCommand), .some(.manualResumeAvailable), nil:
                return false
            }
        }
        return false
    }

    /// Drops the restored-agent snapshot and its resume-progression state for a panel.
    /// Mirrors `Workspace.clearRestoredAgentSnapshot`.
    public func clearRestoredAgentSnapshot(panelId: UUID) {
        restoredAgentSnapshotsByPanelId.removeValue(forKey: panelId)
        restoredAgentResumeStatesByPanelId.removeValue(forKey: panelId)
    }
}
