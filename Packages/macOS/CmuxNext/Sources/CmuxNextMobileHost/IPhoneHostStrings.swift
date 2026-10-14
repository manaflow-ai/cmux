import Foundation

/// User-facing text of Settings > Mobile (the iPhone card). Keys live in Resources/IPhone.xcstrings.
enum IPhoneHostStrings {
    static var connectionTitle: String {
        String(localized: "iphone.connection.title", defaultValue: "Connection", table: "IPhone", bundle: .module)
    }
    static var accountTitle: String { String(localized: "iphone.account.title", defaultValue: "Account", table: "IPhone", bundle: .module) }
    static func registered(as email: String) -> String {
        String(format: String(localized: "iphone.account.registered", defaultValue: "Registered as %@", table: "IPhone", bundle: .module), email)
    }
    static var notConnected: String { String(localized: "iphone.phone.notConnected", defaultValue: "Not connected", table: "IPhone", bundle: .module) }
    static var remove: String { String(localized: "iphone.phone.remove", defaultValue: "Remove", table: "IPhone", bundle: .module) }
    static var removeHelp: String {
        String(localized: "iphone.phone.removeHelp",
               defaultValue: "Removes this phone from your account's devices and ends its connection. A phone still signed in adds itself again when it reconnects.",
               table: "IPhone", bundle: .module)
    }
    static var listFailed: String {
        String(localized: "iphone.phones.listFailed", defaultValue: "Could not load your phones. Check your connection.", table: "IPhone", bundle: .module)
    }
    static var removeFailed: String {
        String(localized: "iphone.phones.removeFailed", defaultValue: "Could not remove this phone. Try again.", table: "IPhone", bundle: .module)
    }
    static var spaceTitle: String { String(localized: "iphone.space.title", defaultValue: "Space", table: "IPhone", bundle: .module) }
    static var statusTitle: String { String(localized: "iphone.status.title", defaultValue: "Status", table: "IPhone", bundle: .module) }
    static var off: String { String(localized: "iphone.status.off", defaultValue: "Off", table: "IPhone", bundle: .module) }
    static var signedOut: String {
        String(localized: "iphone.status.signedOut", defaultValue: "Sign in to cmux to allow iPhone connections.", table: "IPhone", bundle: .module)
    }
    static var unavailable: String {
        String(localized: "iphone.status.unavailable", defaultValue: "iPhone connections are not available in this build.", table: "IPhone", bundle: .module)
    }
    static var connecting: String { String(localized: "iphone.status.connecting", defaultValue: "Connecting…", table: "IPhone", bundle: .module) }
    static var online: String { String(localized: "iphone.status.online", defaultValue: "Online", table: "IPhone", bundle: .module) }
    static var reconnecting: String {
        String(localized: "iphone.status.reconnecting", defaultValue: "Reconnecting…", table: "IPhone", bundle: .module)
    }
    static func phonesConnected(_ count: Int) -> String {
        String(format: String(localized: "iphone.status.phones", defaultValue: "Phones connected: %d", table: "IPhone", bundle: .module), count)
    }
    static var personalSpace: String { String(localized: "iphone.space.personal", defaultValue: "Personal", table: "IPhone", bundle: .module) }
    static var howTitle: String { String(localized: "iphone.how.title", defaultValue: "How to Connect", table: "IPhone", bundle: .module) }
    static var how: String {
        String(localized: "iphone.how.body",
               defaultValue: "Install cmux on your iPhone and sign in with the same account as this Mac. This Mac then appears under Workspaces.",
               table: "IPhone", bundle: .module)
    }
    static var phonesTitle: String { String(localized: "iphone.phones.title", defaultValue: "Phones", table: "IPhone", bundle: .module) }
    static var phonesEmpty: String { String(localized: "iphone.phones.empty", defaultValue: "No phone has connected with this account yet.", table: "IPhone", bundle: .module) }
    static func phone(_ shortID: String) -> String {
        String(format: String(localized: "iphone.phone.title", defaultValue: "iPhone %@", table: "IPhone", bundle: .module), shortID)
    }
    static func since(_ time: String) -> String {
        String(format: String(localized: "iphone.phone.since", defaultValue: "Since %@", table: "IPhone", bundle: .module), time)
    }

    /// A transport's name; product names stay as they are.
    static func transport(_ wire: String) -> String {
        switch wire {
        case "webrtc": "WebRTC"
        case "wireguard": "WireGuard"
        default: wire
        }
    }

    static func path(_ wire: String) -> String {
        switch wire {
        case "direct": String(localized: "iphone.path.direct", defaultValue: "Direct", table: "IPhone", bundle: .module)
        case "relay": String(localized: "iphone.path.relay", defaultValue: "Relayed", table: "IPhone", bundle: .module)
        case "turn": String(localized: "iphone.path.turn", defaultValue: "Relayed (TURN)", table: "IPhone", bundle: .module)
        default: wire
        }
    }
}
