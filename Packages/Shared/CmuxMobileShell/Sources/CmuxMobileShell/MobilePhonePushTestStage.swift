/// The furthest stage a user-triggered test alert has confirmed.
///
/// `queuedOnMac` deliberately does not claim APNs acceptance or visible iOS
/// presentation. Those later stages remain observable through correlated Mac,
/// backend, and device evidence rather than a false-success button label.
public enum MobilePhonePushTestStage: String, Equatable, Sendable {
    case queuedOnMac = "queued"
    case forwardingDisabled = "forwarding_disabled"
    case macActive = "suppressed_mac_active"
    case authenticationUnavailable = "authentication_unavailable"
    case encodingFailed = "encoding_failed"
    case queueFull = "queue_full"
    case unavailable
}
