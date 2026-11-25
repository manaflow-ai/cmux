import Foundation

/// User-facing text of Settings > Mobile (the iPhone card). Keys live in Resources/IPhone.xcstrings.
enum IPhoneHostStrings {
    static var connectionTitle: String {
        String(localized: "iphone.connection.title", defaultValue: "Connection", table: "IPhone", bundle: .localizedModule)
    }
    static var accountTitle: String { String(localized: "iphone.account.title", defaultValue: "Account", table: "IPhone", bundle: .localizedModule) }
    static func registered(as email: String) -> String {
        String(format: String(localized: "iphone.account.registered", defaultValue: "Registered as %@", table: "IPhone", bundle: .localizedModule), email)
    }
    static var notConnected: String { String(localized: "iphone.phone.notConnected", defaultValue: "Not connected", table: "IPhone", bundle: .localizedModule) }
    static var remove: String { String(localized: "iphone.phone.remove", defaultValue: "Remove", table: "IPhone", bundle: .localizedModule) }
    static var removeHelp: String {
        String(localized: "iphone.phone.removeHelp",
               defaultValue: "Removes this phone from your account's devices and ends its connection. A phone still signed in adds itself again when it reconnects.",
               table: "IPhone", bundle: .localizedModule)
    }
    static var listFailed: String {
        String(localized: "iphone.phones.listFailed", defaultValue: "Could not load your phones. Check your connection.", table: "IPhone", bundle: .localizedModule)
    }
    static var removeFailed: String {
        String(localized: "iphone.phones.removeFailed", defaultValue: "Could not remove this phone. Try again.", table: "IPhone", bundle: .localizedModule)
    }
    static var removed: String {
        String(localized: "iphone.status.removed",
               defaultValue: "This Mac was removed from your account's devices, so your iPhone can't reach it. Choose Allow Again to let your iPhone connect.",
               table: "IPhone", bundle: .localizedModule)
    }
    static var allowAgain: String { String(localized: "iphone.allowAgain", defaultValue: "Allow Again", table: "IPhone", bundle: .localizedModule) }
    static var spaceTitle: String { String(localized: "iphone.space.title", defaultValue: "Space", table: "IPhone", bundle: .localizedModule) }
    static var statusTitle: String { String(localized: "iphone.status.title", defaultValue: "Status", table: "IPhone", bundle: .localizedModule) }
    static var off: String { String(localized: "iphone.status.off", defaultValue: "Off", table: "IPhone", bundle: .localizedModule) }
    static var signedOut: String {
        String(localized: "iphone.status.signedOut", defaultValue: "Sign in to cmux to allow iPhone connections.", table: "IPhone", bundle: .localizedModule)
    }
    static var unavailable: String {
        String(localized: "iphone.status.unavailable", defaultValue: "iPhone connections are not available in this build.", table: "IPhone", bundle: .localizedModule)
    }
    /// A refused Keychain read of this Mac's iPhone key: the host waits and tries again.
    static var keychainLocked: String {
        String(localized: "iphone.status.keychainLocked", defaultValue: "Waiting for the login keychain to unlock. iPhones connect once it does.",
               table: "IPhone", bundle: .localizedModule)
    }
    static var connecting: String { String(localized: "iphone.status.connecting", defaultValue: "Connecting…", table: "IPhone", bundle: .localizedModule) }
    static var online: String { String(localized: "iphone.status.online", defaultValue: "Online", table: "IPhone", bundle: .localizedModule) }
    static var reconnecting: String {
        String(localized: "iphone.status.reconnecting", defaultValue: "Reconnecting…", table: "IPhone", bundle: .localizedModule)
    }
    static func phonesConnected(_ count: Int) -> String {
        String(format: String(localized: "iphone.status.phones", defaultValue: "Phones connected: %d", table: "IPhone", bundle: .localizedModule), count)
    }
    static var personalSpace: String { String(localized: "iphone.space.personal", defaultValue: "Personal", table: "IPhone", bundle: .localizedModule) }
    static var howTitle: String { String(localized: "iphone.how.title", defaultValue: "How to Connect", table: "IPhone", bundle: .localizedModule) }
    static var how: String {
        String(localized: "iphone.how.body",
               defaultValue: "Install cmux on your iPhone and sign in with the same account as this Mac. This Mac then appears under Workspaces. No cmux on your iPhone yet? It’s in beta: get it through TestFlight.",
               table: "IPhone", bundle: .localizedModule)
    }
    static var phonesTitle: String { String(localized: "iphone.phones.title", defaultValue: "Phones", table: "IPhone", bundle: .localizedModule) }
    static var phonesEmpty: String { String(localized: "iphone.phones.empty", defaultValue: "No phone has connected with this account yet.", table: "IPhone", bundle: .localizedModule) }
    static func phone(_ shortID: String) -> String {
        String(format: String(localized: "iphone.phone.title", defaultValue: "iPhone %@", table: "IPhone", bundle: .localizedModule), shortID)
    }
    static func phoneAccessPhone(_ name: String) -> String {
        String(format: String(localized: "iphone.phone.transport.next", defaultValue: "%@ · cmux next", table: "IPhone", bundle: .localizedModule), name)
    }
    static func legacyPhone(_ name: String) -> String {
        String(format: String(localized: "iphone.phone.transport.ios", defaultValue: "%@ · cmux (iOS)", table: "IPhone", bundle: .localizedModule), name)
    }
    /// The phone's name with its short key fingerprint beside it (``MobileHostPairRequest/shortFingerprint``).
    static func pairTitle(_ name: String, key: String) -> String {
        String(format: String(localized: "iphone.pair.title", defaultValue: "Allow “%1$@” (%2$@) to connect to this Mac?", table: "IPhone", bundle: .localizedModule),
               name, key)
    }
    static func pairBody(_ account: String) -> String {
        String(format: String(localized: "iphone.pair.body",
                              defaultValue: "It is signed in as %@. Once allowed, it can open your terminals and agent chats, and approve agent actions with Face ID.",
                              table: "IPhone", bundle: .localizedModule), account)
    }
    /// The body for another of the person's computers asking (docs/multi-machine-sessions.md): it
    /// starts with `view` only, so the prompt says that and where to widen it.
    static func machinePairBody(_ account: String) -> String {
        String(format: String(localized: "iphone.pair.machineBody",
                              defaultValue: "It is your Mac, signed in as %@. Once allowed, it can see this Mac’s name and what it may do here, nothing more: it cannot see your work until you choose what it may do in Settings > Devices. Remove it there to stop it at once.",
                              table: "IPhone", bundle: .localizedModule), account)
    }
    static func pairKey(_ fingerprint: String) -> String {
        String(format: String(localized: "iphone.pair.key", defaultValue: "Device key %@", table: "IPhone", bundle: .localizedModule), fingerprint)
    }
    static var pairAllow: String { String(localized: "iphone.pair.allow", defaultValue: "Allow", table: "IPhone", bundle: .localizedModule) }
    static var pairDeny: String { String(localized: "iphone.pair.deny", defaultValue: "Don't Allow", table: "IPhone", bundle: .localizedModule) }
    static var unnamedPhone: String { String(localized: "iphone.pair.unnamed", defaultValue: "iPhone", table: "IPhone", bundle: .localizedModule) }
    static func signedInAs(_ account: String) -> String {
        String(format: String(localized: "iphone.pair.account", defaultValue: "Signed in as %@", table: "IPhone", bundle: .localizedModule), account)
    }
    /// When the backend registered the asking phone: "Registered today" makes a brand-new device stand out.
    static func deviceRegistered(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "iphone.pair.registered.today", defaultValue: "Registered today", table: "IPhone", bundle: .localizedModule)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "iphone.pair.registered.yesterday", defaultValue: "Registered yesterday", table: "IPhone", bundle: .localizedModule)
        }
        return String(format: String(localized: "iphone.pair.registered.date", defaultValue: "Registered %@", table: "IPhone", bundle: .localizedModule),
                      date.formatted(date: .abbreviated, time: .omitted))
    }
    static func noticeTitle(_ name: String) -> String {
        String(format: String(localized: "iphone.notice.title", defaultValue: "“%@” wants to connect to this Mac", table: "IPhone", bundle: .localizedModule), name)
    }
    static var noticeReview: String { String(localized: "iphone.notice.review", defaultValue: "Review", table: "IPhone", bundle: .localizedModule) }
    static var pendingTitle: String { String(localized: "iphone.pending.title", defaultValue: "Connection Requests", table: "IPhone", bundle: .localizedModule) }
    static func blocked(_ count: Int) -> String {
        String(format: String(localized: "iphone.pending.blocked", defaultValue: "Blocked requests: %lld", table: "IPhone", bundle: .localizedModule), count)
    }
    static var blockedHelp: String {
        String(localized: "iphone.pending.blockedHelp",
               defaultValue: "After you choose Don't Allow, new requests from this account are ignored for 10 minutes, and too many at once are ignored too.",
               table: "IPhone", bundle: .localizedModule)
    }
    static func since(_ time: String) -> String {
        String(format: String(localized: "iphone.phone.since", defaultValue: "Since %@", table: "IPhone", bundle: .localizedModule), time)
    }

    /// A transport's name; product names stay as they are.
    static func transport(_ wire: String) -> String {
        switch wire {
        case "webrtc": "WebRTC"
        case "wireguard": "WireGuard"
        // Tailscale only: plain TCP over the person's tailnet (PROTOCOL.md "Tailscale-only links").
        case "tailnet": "Tailscale"
        default: wire
        }
    }

    /// The WebRTC media session beside a WireGuard link (browser video): "Video over WebRTC (TURN)".
    static func videoWebRTC(_ wire: String) -> String {
        switch wire {
        case "direct": String(localized: "iphone.media.direct", defaultValue: "Video over WebRTC (direct)", table: "IPhone", bundle: .localizedModule)
        case "turn": String(localized: "iphone.media.turn", defaultValue: "Video over WebRTC (TURN)", table: "IPhone", bundle: .localizedModule)
        default: String(localized: "iphone.media.other", defaultValue: "Video over WebRTC", table: "IPhone", bundle: .localizedModule)
        }
    }

    static func path(_ wire: String) -> String {
        switch wire {
        case "direct": String(localized: "iphone.path.direct", defaultValue: "Direct", table: "IPhone", bundle: .localizedModule)
        case "relay": String(localized: "iphone.path.relay", defaultValue: "Relayed", table: "IPhone", bundle: .localizedModule)
        case "turn": String(localized: "iphone.path.turn", defaultValue: "Relayed (TURN)", table: "IPhone", bundle: .localizedModule)
        case "turn-tls": String(localized: "iphone.path.turnTls", defaultValue: "Relayed (TURN over TLS)", table: "IPhone", bundle: .localizedModule)
        case "https-relay": String(localized: "iphone.path.httpsRelay", defaultValue: "Relayed (cmux over HTTPS)", table: "IPhone", bundle: .localizedModule)
        case "none": String(localized: "iphone.path.none", defaultValue: "No path", table: "IPhone", bundle: .localizedModule)
        default: wire
        }
    }
}
