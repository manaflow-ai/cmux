import Foundation

/// The pairing window's strings (Localizable.xcstrings in this module).
struct PhonePairingStrings {
    static var windowTitle: String { String(localized: "pairing.window.title", defaultValue: "Pair iPhone", bundle: .module) }
    static var title: String { String(localized: "pairing.title", defaultValue: "Pair your iPhone", bundle: .module) }
    static var subtitle: String {
        String(localized: "pairing.subtitle",
               defaultValue: "Open cmux on your iPhone and scan this code. It works once and expires in 10 minutes.",
               bundle: .module)
    }
    static var newCode: String { String(localized: "pairing.newCode", defaultValue: "New Code", bundle: .module) }
    static var copyLink: String { String(localized: "pairing.copyLink", defaultValue: "Copy Link", bundle: .module) }
    static var devices: String { String(localized: "pairing.devices", defaultValue: "Paired Phones", bundle: .module) }
    static var noDevices: String { String(localized: "pairing.noDevices", defaultValue: "No phones paired yet.", bundle: .module) }
    static var connected: String { String(localized: "pairing.connected", defaultValue: "Connected", bundle: .module) }
    static var notConnected: String { String(localized: "pairing.notConnected", defaultValue: "Not connected", bundle: .module) }
    static var unpair: String { String(localized: "pairing.unpair", defaultValue: "Unpair", bundle: .module) }
    static var orType: String {
        String(localized: "pairing.orType", defaultValue: "Or type this code on an iPhone on the same network", bundle: .module)
    }

    static func codeLabel(_ code: String) -> String {
        String(format: String(localized: "pairing.codeLabel", defaultValue: "Pairing code %@", bundle: .module), code)
    }

    static var qrLabel: String { String(localized: "pairing.qrLabel", defaultValue: "Pairing code", bundle: .module) }

    static func expires(_ time: String) -> String {
        String(format: String(localized: "pairing.expires", defaultValue: "Expires at %@", bundle: .module), time)
    }

    static func paired(_ name: String) -> String {
        String(format: String(localized: "pairing.paired", defaultValue: "Paired with %@", bundle: .module), name)
    }

    static func lastSeen(_ when: String) -> String {
        String(format: String(localized: "pairing.lastSeen", defaultValue: "Last seen %@", bundle: .module), when)
    }

    static func encrypted(_ fingerprint: String) -> String {
        String(format: String(localized: "pairing.encrypted", defaultValue: "End-to-end encrypted with WireGuard. Mac key %@",
                              bundle: .module), fingerprint)
    }

    static func reachable(_ endpoints: String) -> String {
        String(format: String(localized: "pairing.reachable", defaultValue: "Phones reach this Mac at %@", bundle: .module), endpoints)
    }

    static func unavailable(_ reason: String) -> String {
        String(format: String(localized: "pairing.unavailable", defaultValue: "Phone access is off: %@", bundle: .module), reason)
    }
}
