import Foundation

/// The single gate decision used for both queueing and superseded-banner sync.
enum PhonePushForwardAdmission: Equatable, Sendable {
    case disabled
    case presenceSuppressed
    case authenticationUnavailable
    case encodingFailed
    case queueFull
    case queued

    /// Wire value returned by `phone_push.test`. It states only the furthest
    /// synchronous stage the Mac can prove and never implies APNs acceptance
    /// or visible presentation on the phone.
    var testStageRawValue: String {
        switch self {
        case .disabled: "forwarding_disabled"
        case .presenceSuppressed: "suppressed_mac_active"
        case .authenticationUnavailable: "authentication_unavailable"
        case .encodingFailed: "encoding_failed"
        case .queueFull: "queue_full"
        case .queued: "queued"
        }
    }
}
