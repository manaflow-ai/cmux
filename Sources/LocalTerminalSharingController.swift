import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// Executes store actions for one local terminal against its Mac host.
@MainActor
final class LocalTerminalSharingController: TerminalSharingSurfaceControlling {
    let surfaceID: UUID
    weak var surface: TerminalSurface?
    private weak var owner: TerminalController?

    init(surfaceID: UUID, surface: TerminalSurface, owner: TerminalController) {
        self.surfaceID = surfaceID
        self.surface = surface
        self.owner = owner
    }

    /// The Mac pane's grid without any shared-sizing cap.
    func naturalViewport() -> TerminalGridSize? {
        surface?.naturalGridSize().map { TerminalGridSize(cols: $0.columns, rows: $0.rows) }
    }

    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        owner?.localSizingSetPolicy(surfaceID: surfaceID, policy: policy) ?? false
    }

    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool {
        owner?.localSizingSetCountsOverride(surfaceID: surfaceID, participantID: participantID, value: value) ?? false
    }

    func sharingDisconnect(participantID: String, by: TerminalDetachActor?) -> Bool {
        owner?.localSizingDisconnect(surfaceID: surfaceID, participantID: participantID, by: by) ?? false
    }

    func sharingNoteSelfActivity() {
        owner?.localSizingNoteSelfActivity(surfaceID: surfaceID)
    }

    /// Reattaches the Mac pane's view after a phone or viewing Mac detached it.
    func sharingReattach(asViewer: Bool) -> Bool {
        owner?.localSizingReattachMac(surfaceID: surfaceID, asViewer: asViewer) ?? false
    }
}
