import CmuxCloud
import CmuxCloudTui
import Foundation

/// What a refresh pass does with one open pane's resolution result.
///
/// A pass re-resolves every session's numeric surface after a socket change or
/// a disconnect. That lookup rides the same link the attachments do, so a
/// transient "transport closed" or an ordered-lane timeout answers `retryable`
/// for panes whose byte stream is perfectly healthy. Fencing those tore down
/// working terminals for no visible reason. A stream that is actually dead
/// reports itself (`.transportClosed`, a liveness timeout); the pass only needs
/// to act on sessions that are not attached, on a changed numeric id, or on a
/// terminal that exited.
enum CloudAttachmentReconcileDecision: Equatable, Sendable {
    /// Rebind to the resolved numeric surface (a no-op when unchanged).
    case rebind(surfaceID: UInt64)
    /// The terminal ended on the machine: stop the session and close its pane.
    case exited
    /// Drop the current stream and let the provider's bounded retry re-resolve.
    case fence(CloudTerminalAttachmentInterruption)
    /// Leave the working stream alone; nothing about it is in doubt.
    case keep

    static func decide(
        phase: CloudTuiManualMirrorPhase,
        resolution: CloudTuiSurfaceIDResolution
    ) -> CloudAttachmentReconcileDecision {
        switch resolution {
        case let .resolved(surfaceID):
            return .rebind(surfaceID: surfaceID)
        case .exited:
            return .exited
        case .noPlacement:
            return phase == .attached
                ? .keep
                : .fence(.unresolved("the machine shows no view of this terminal"))
        case let .retryable(reason, _):
            return phase == .attached ? .keep : .fence(.unresolved(reason))
        }
    }

    /// Whether the pass must arm its bounded retry because of this decision.
    var needsRetry: Bool {
        if case .fence = self { return true }
        return false
    }
}
