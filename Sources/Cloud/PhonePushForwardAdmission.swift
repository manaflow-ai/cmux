import Foundation

/// The single gate decision used for both queueing and superseded-banner sync.
enum PhonePushForwardAdmission: Equatable, Sendable {
    case disabled
    case presenceSuppressed
    case authenticationUnavailable
    case queueFull
    case queued
}
