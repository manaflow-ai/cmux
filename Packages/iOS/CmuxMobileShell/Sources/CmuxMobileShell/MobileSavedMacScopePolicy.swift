import Foundation

/// Decides whether a tagged dev iOS build may auto-connect to a saved Mac,
/// based on what that Mac's presence heartbeat reports about ITS build.
///
/// Tagged dev builds are isolated identities on purpose (own bundle id, own
/// debug socket, own device UUID). A dev phone's saved-Mac list accumulates one
/// "Mac" per tagged Mac app it ever paired with — all named after the same
/// physical machine — and the multi-Mac aggregation used to dial every one of
/// them, so a `dl2` phone would attach to whatever OTHER agents' tagged dev
/// instances happened to be running (observed in dogfood). The rule:
///
/// - An UNSCOPED phone (release/TestFlight) connects to anything (unchanged).
/// - A scoped dev phone connects to: the dev Mac whose tag matches its own,
///   any non-dev Mac (Stable/Nightly/RC — real product installs), and Macs
///   whose build is UNKNOWN (no presence data; usually offline, and refusing
///   them would break reconnect to a Mac that merely stopped heartbeating).
/// - A scoped dev phone REFUSES a dev Mac with a different tag.
///
/// Tags are compared through the same ASCII slug transform the reload scripts
/// use for sockets/bundle ids, because the iOS scope value may be the DOTTED
/// bundle suffix ("my.tag") while the Mac heartbeats the DASHED reload tag
/// ("my-tag").
enum MobileSavedMacScopePolicy {
    /// The Mac-side tagged Debug bundle prefix (`com.cmuxterm.app.debug.<seg>`).
    private static let macDevBundlePrefix = "com.cmuxterm.app.debug."

    /// The tri-state scope verdict. Callers choose how to treat
    /// ``unknownIdentity`` by surface: secondary aggregation and non-active
    /// reconnect candidates fail CLOSED (skip until presence delivers the
    /// build identity — they re-run once it does), while the ACTIVE Mac fails
    /// OPEN (it is the user's own last-used Mac, and refusing it during a
    /// presence outage would strand offline reconnect entirely).
    enum Decision: Equatable {
        case allowed
        case unknownIdentity
        case refused
    }

    static func decision(
        macDevTag: String?,
        macBundleID: String?,
        iosScope: MobileIOSBuildScope?
    ) -> Decision {
        guard let iosScope else { return .allowed }
        // The Mac's dev tag: an explicit non-"default" heartbeat tag wins;
        // otherwise derive it from a tagged Debug bundle id.
        let trimmedTag = macDevTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        var devTag: String?
        if let trimmedTag, !trimmedTag.isEmpty, trimmedTag != "default" {
            devTag = trimmedTag
        } else if let bundle = macBundleID?.lowercased(), bundle.hasPrefix(macDevBundlePrefix) {
            devTag = String(bundle.dropFirst(macDevBundlePrefix.count))
        }
        if let devTag {
            return slug(devTag) == slug(iosScope.value) ? .allowed : .refused
        }
        // A known NON-dev build (stable/nightly/rc bundle) is a real product
        // install: always dialable. No identity at all is the ambiguous case.
        if let bundle = macBundleID?.lowercased(), !bundle.isEmpty {
            return .allowed
        }
        return .unknownIdentity
    }

    /// Lowercased ASCII alphanumerics with every other run collapsed to "-",
    /// mirroring the reload scripts' tag slug so dotted bundle segments and
    /// dashed tags compare equal.
    static func slug(_ value: String) -> String {
        var out: [Character] = []
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
        }
        return String(out)
    }
}
