import Foundation

@MainActor
extension CloudTuiManualMirrorSession {
    /// Removes size and claim responses that belong to a hidden projection.
    func discardPendingSizingRequests() {
        pendingRequests = pendingRequests.filter { _, kind in
            switch kind {
            case .resize(_), .claim:
                return false
            case .identify, .clientInfo, .attach, .ping:
                return true
            }
        }
    }

    /// Returns whether a sizing claim is unavailable on an older daemon.
    static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }

    func applyReplay(_ bytes: Data, reset: Bool) {
        if reset {
            // Drop every remote color before the reset rather than trusting
            // RIS to do it: the replay's own sidecar re-applies the authored
            // set in full, so the pane ends in the same state either way.
            applyColors(CloudTuiRemoteColors())
            surface?.processRemoteOutput(Self.replayReset)
        }
        surface?.processRemoteOutput(bytes)
    }

    /// The replay is theme-portable: it carries no palette or default-color
    /// OSC state, so the local Ghostty theme stands for every color the
    /// remote PTY did not author. The sidecar restores the authored ones and
    /// is a full sparse replacement, so an entry that vanished since the last
    /// sidecar is reset back to the local theme. A frame with no sidecar
    /// leaves the applied colors alone.
    func applyColors(_ colors: CloudTuiRemoteColors?) {
        guard let colors else { return }
        let delta = colors.oscDelta(from: appliedRemoteColors)
        appliedRemoteColors = colors
        guard !delta.isEmpty else { return }
        surface?.processRemoteOutput(delta)
    }

}
