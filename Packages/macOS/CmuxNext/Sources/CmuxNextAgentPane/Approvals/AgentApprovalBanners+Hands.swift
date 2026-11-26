import Foundation

/// The texts of Chief hand requests in these banners (docs/chief-hands.md, cx-om025): a hand's
/// waiting request posts in the same category (Allow once, Deny), and a level raise names the hand
/// and the level in the Touch ID / password prompt. Levels and profiles are the server's raw values
/// (`full`, `auto`, `ask`, `read-only`; `sandbox`, `mac`).
extension AgentApprovalBanners {
    /// The banner title of a hand's waiting request.
    public nonisolated static func handTitle(_ name: String) -> String {
        String(format: String(localized: "hands.approval.title", defaultValue: "%@ asks for approval", bundle: .localizedModule), name)
    }

    /// A level's name for people.
    public nonisolated static func handLevelName(_ level: String) -> String {
        switch level {
        case "full": String(localized: "hands.level.full", defaultValue: "Full", bundle: .localizedModule)
        case "auto": String(localized: "hands.level.auto", defaultValue: "Auto", bundle: .localizedModule)
        case "ask": String(localized: "hands.level.ask", defaultValue: "Ask", bundle: .localizedModule)
        case "read-only": String(localized: "hands.level.readOnly", defaultValue: "Read only", bundle: .localizedModule)
        default: level
        }
    }

    /// The presence prompt's reason for raising hand `name` to `level`.
    public nonisolated static func handRaiseReason(_ name: String, level: String) -> String {
        String(format: String(localized: "hands.raise.hand", defaultValue: "raise the hand “%1$@” to %2$@", bundle: .localizedModule),
               name, handLevelName(level))
    }

    /// The presence prompt's reason for raising the default level of new `profile` hands.
    public nonisolated static func handDefaultRaiseReason(profile: String, level: String) -> String {
        let format = profile == "mac"
            ? String(localized: "hands.raise.default.mac", defaultValue: "raise the default level of new Mac hands to %@", bundle: .localizedModule)
            : String(localized: "hands.raise.default.sandbox", defaultValue: "raise the default level of new sandbox hands to %@", bundle: .localizedModule)
        return String(format: format, handLevelName(level))
    }

    /// `HandsService.texts`: the presence prompt reasons by raw level and profile values.
    public nonisolated static var handTexts: (raiseHand: (String, String) -> String, raiseDefault: (String, String) -> String,
                                              unavailable: String, notLinked: String) {
        ({ handRaiseReason($0, level: $1) }, { handDefaultRaiseReason(profile: $0, level: $1) }, handPresenceUnavailable, handNotLinked)
    }

    /// Why Allow or a raise does nothing: this Mac has no registered Cloud install (signed out, or Cloud is off here).
    public nonisolated static var handNotLinked: String {
        String(localized: "hands.install.notLinked",
               defaultValue: "This Mac is not set up for Cloud, so it cannot confirm this. Choose Sign In to cmux, then try again.",
               bundle: .localizedModule)
    }

    /// Why this Mac refuses a raise: it has no Secure Enclave for the presence key.
    public nonisolated static var handPresenceUnavailable: String {
        String(localized: "hands.presence.unavailable",
               defaultValue: "This Mac has no Secure Enclave, so it cannot confirm that you are present. A hand's level can only be lowered from this Mac.",
               bundle: .localizedModule)
    }
}
