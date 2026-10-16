import Foundation
import Observation

/// The one observable fact a native cloud pane needs about its attachment.
///
/// Owned by ``CloudTuiManualMirrorSession`` and handed to the pane's panel by
/// reference, so the pane can show a reconnecting state without reaching into
/// the session. Only the session writes it.
@MainActor
@Observable
public final class CloudTerminalAttachmentStatus {
    public let machineID: String
    public private(set) var state: CloudTerminalAttachmentState = .attaching(attempt: 1)
    /// One-shot style hook for owners that are not SwiftUI views (the workspace
    /// clearing an optimistic pane's tab spinner). Set by the pane owner only.
    @ObservationIgnored public var onStateChange: (@MainActor (CloudTerminalAttachmentState) -> Void)?

    public init(machineID: String) {
        self.machineID = machineID
    }

    public func update(_ state: CloudTerminalAttachmentState) {
        guard self.state != state else { return }
        self.state = state
        onStateChange?(state)
    }
}
