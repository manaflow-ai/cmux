import Foundation

/// Refines WHEN notifications are forwarded once
/// ``PhonePushSettings/forwardEnabledKey`` is on. It never widens forwarding:
/// the master toggle stays the opt-in.
enum PhoneForwardingMode: String, CaseIterable {
    /// Forward only while the user is away from this Mac (the default,
    /// including for users who enabled forwarding before this mode existed).
    case onlyWhenAway
    /// Forward every notification regardless of Mac presence.
    case always

    static let defaultMode: PhoneForwardingMode = .onlyWhenAway

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> PhoneForwardingMode {
        guard let raw = defaults.string(forKey: PhonePushSettings.forwardModeKey),
              let mode = PhoneForwardingMode(rawValue: raw)
        else {
            return defaultMode
        }
        return mode
    }
}
