import Foundation
import Observation

/// The one observable fact a native cloud pane needs about its attachment.
///
/// Owned by ``CloudTuiManualMirrorSession`` and handed to the pane's panel by
/// reference, so the pane can show a reconnecting state without reaching into
/// the session. Only the session writes it.
@MainActor
@Observable
final class CloudTerminalAttachmentStatus {
    let machineID: String
    private(set) var state: CloudTerminalAttachmentState = .attaching(attempt: 1)
    /// The overlay snapshot owned by the same attachment as ``state``.
    ///
    /// A native Cloud panel must not fall back to workspace-wide controller
    /// state when its catalog projection is temporarily unavailable. Keeping
    /// the presentation beside the attachment state makes that ownership
    /// explicit and survives catalog refreshes and pane moves.
    private(set) var presentation: CloudTerminalReconnectOverlayPolicy.Presentation?
    /// One-shot style hook for owners that are not SwiftUI views (the workspace
    /// clearing an optimistic pane's tab spinner). Set by the pane owner only.
    @ObservationIgnored var onStateChange: (@MainActor (CloudTerminalAttachmentState) -> Void)?

    init(machineID: String) {
        self.machineID = machineID
    }

    func update(
        _ state: CloudTerminalAttachmentState,
        presentation: CloudTerminalReconnectOverlayPolicy.Presentation?
    ) {
        let stateChanged = self.state != state
        guard stateChanged || self.presentation != presentation else { return }
        self.state = state
        self.presentation = presentation
        if stateChanged { onStateChange?(state) }
    }
}
