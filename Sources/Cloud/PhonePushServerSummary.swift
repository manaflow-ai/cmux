import Foundation

/// Sanitized acknowledgement returned by the push API after APNs fan-out.
struct PhonePushServerSummary: Codable, Equatable, Sendable {
    let sent: Int
    let devices: Int
    let pruned: Int
    let transientFailures: Int
    let permanentFailures: Int
    let retryAfterSeconds: Int?

    init(
        sent: Int,
        devices: Int,
        pruned: Int,
        transientFailures: Int,
        permanentFailures: Int,
        retryAfterSeconds: Int? = nil
    ) {
        self.sent = sent
        self.devices = devices
        self.pruned = pruned
        self.transientFailures = transientFailures
        self.permanentFailures = permanentFailures
        self.retryAfterSeconds = retryAfterSeconds
    }
}
