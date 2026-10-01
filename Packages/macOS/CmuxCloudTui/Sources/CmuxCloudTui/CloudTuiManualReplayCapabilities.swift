import Foundation

/// Capability policy shared by the native Cloud mirror and its transport
/// tests. A daemon that advertises modern attachment features without
/// pending-sequence framing can corrupt a replay at a VT boundary.
public enum CloudTuiManualReplayCapabilities {
    private static let modernCapabilities: Set<String> = [
        "attach-identity-v1",
        "attach-initial-size",
        "shared-sizing-v1",
        "sizing-view-detach-v1",
        "terminal-color-overrides-v1",
        "view-attachment-detach-v1",
        "view-attachment-lease-v1",
    ]

    /// Returns true when a successful identify response describes a daemon
    /// too old to safely replay incomplete VT sequences.
    public static func isStaleReplayDaemon(capabilities: [String]) -> Bool {
        let advertised = Set(capabilities)
        return !advertised.isDisjoint(with: modernCapabilities)
            && !advertised.contains(CloudTuiManualIOCommand().terminalPendingSequenceCapability)
    }
}
