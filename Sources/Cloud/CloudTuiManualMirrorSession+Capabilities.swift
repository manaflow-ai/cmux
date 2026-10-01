import Foundation

extension CloudTuiManualMirrorSession {
    /// A successful identify from a daemon that knows modern attachment
    /// features but omits pending-sequence framing is unsafe for replay. Keep
    /// truly old peers (which report no capabilities) on the compatibility
    /// path; they do not claim the newer protocol surface.
    nonisolated static func isStaleReplayDaemon(capabilities: [String]) -> Bool {
        let modernCapabilities: Set<String> = [
            "attach-identity-v1",
            "attach-initial-size",
            "shared-sizing-v1",
            "sizing-view-detach-v1",
            "terminal-color-overrides-v1",
            "view-attachment-detach-v1",
            "view-attachment-lease-v1",
        ]
        let advertised = Set(capabilities)
        return !advertised.isDisjoint(with: modernCapabilities)
            && !advertised.contains(CloudTuiManualIOCommand().terminalPendingSequenceCapability)
    }

    /// Never downgrades to an unleased attachment when the peer promises fencing.
    nonisolated static func requiresLeaseToken(capabilities: [String], lease: String?) -> Bool {
        capabilities.contains("view-attachment-lease-v1") && lease?.isEmpty != false
    }

    /// Recognizes capability errors from daemons that predate geometry claims.
    static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }
}
