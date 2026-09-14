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

    init(machineID: String) {
        self.machineID = machineID
    }

    func update(_ state: CloudTerminalAttachmentState) {
        guard self.state != state else { return }
        self.state = state
    }
}
