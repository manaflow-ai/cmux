import Foundation

/// The journal hook this Mac registers on each Cloud machine's cmux-tui daemon
/// so agent events in the machine reach this Mac. The guest side is
/// `cmux-tui host-forward` (`cmux-tui/crates/cmux-tui/src/host_forward.rs`),
/// which reads `/etc/cmux/host.env` (written by `VMHostListenerCoordinator`)
/// and dials the listener with the machine's token. Both sides must agree on
/// this manifest; the guest validates it on `session.journal.hook.put`.
enum VMHostForwardHook {
    static let hookID = "cmux_host_forward"
    static let manifestVersion = 1
    /// Where the daemon image links the cmux-tui binary (`cmuxTuiDaemon.ts`).
    static let guestBinaryPath = "/usr/local/bin/cmux-tui"
    /// Same vocabulary as the guest's `FORWARDED_KINDS`.
    static let forwardedKinds = [
        "agent.turn.started",
        "agent.turn.completed",
        "agent.approval.requested",
        "agent.question.requested",
        "agent.plan_review.requested",
        "agent.error.reported",
        "agent.session.ended",
    ]

    static func manifest(binaryPath: String = guestBinaryPath) -> [String: Any] {
        [
            "hook_id": hookID,
            "manifest_version": manifestVersion,
            "filter": ["kinds": forwardedKinds],
            "exec": ["argv": [binaryPath, "host-forward"], "timeout_ms": 15_000, "max_parallel": 2],
            "delivery": ["start": "tail", "retry": ["max_attempts": 3, "backoff_ms": 2_000]],
            "permissions": ["journal.read"],
        ]
    }

    static func manifestJSON(binaryPath: String = guestBinaryPath) -> String {
        let data = try! JSONSerialization.data(withJSONObject: manifest(binaryPath: binaryPath), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
