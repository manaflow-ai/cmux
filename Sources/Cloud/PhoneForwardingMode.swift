import Foundation

/// Refines when an enabled Mac forwards notifications. Missing preferences use
/// ``defaultMode``; an explicitly stored master-toggle choice stays authoritative.
enum PhoneForwardingMode: String, CaseIterable, Sendable {
    /// Forward only while the user is away from this Mac.
    case onlyWhenAway
    /// Forward every notification regardless of Mac presence.
    case always

    static let defaultMode: PhoneForwardingMode = .always

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> PhoneForwardingMode {
        guard let raw = defaults.string(forKey: PhonePushSettings.forwardModeKey),
              let mode = PhoneForwardingMode(rawValue: raw)
        else {
            return defaultMode
        }
        return mode
    }
}
