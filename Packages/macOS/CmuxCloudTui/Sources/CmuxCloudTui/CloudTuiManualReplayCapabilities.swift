import Foundation

/// Replay compatibility policy for the native Cloud mirror.
///
/// This lives on the command owner so capability names cannot drift between
/// handshake advertisement and stale-daemon detection.
extension CloudTuiManualIOCommand {
    private static let modernReplayCapabilities: Set<String> = [
        Self.viewAttachmentLeaseCapability,
        Self.viewAttachmentDetachCapability,
        Self.sharedSizingCapability,
        Self.sizingViewDetachCapability,
        "attach-identity-v1",
        "attach-initial-size",
        "terminal-color-overrides-v1",
    ]

    /// Returns true when a successful identify response describes a daemon
    /// too old to safely replay incomplete VT sequences.
    public func isStaleReplayDaemon(capabilities: [String]) -> Bool {
        let advertised = Set(capabilities)
        return !advertised.isDisjoint(with: Self.modernReplayCapabilities)
            && !advertised.contains(Self.terminalPendingSequenceCapability)
    }
}
