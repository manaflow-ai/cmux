import Foundation

/// Sanitized acknowledgement returned by the push API after APNs fan-out.
public struct PhonePushServerSummary: Codable, Equatable, Sendable {
    public let sent: Int
    public let devices: Int
    public let pruned: Int
    public let transientFailures: Int
    public let permanentFailures: Int
    public let retryAfterSeconds: Int?

    public init(
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
