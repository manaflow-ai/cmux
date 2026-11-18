import Foundation

/// The MCP connect card's user-facing strings (Home's Localizable.xcstrings).
enum McpConnectStrings {
    static func connectTitle(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.title", defaultValue: "Connect %@?", bundle: .l10n), title)
    }
    static func asks(_ agent: String) -> String {
        String(format: String(localized: "home.mcpConnect.asks", defaultValue: "%@ asks:", bundle: .l10n), agent)
    }
    static var verified: String { String(localized: "home.mcpConnect.verified", defaultValue: "Verified", bundle: .l10n) }
    static var unverified: String { String(localized: "home.mcpConnect.unverified", defaultValue: "Unverified", bundle: .l10n) }
    static var server: String { String(localized: "home.mcpConnect.server", defaultValue: "Server", bundle: .l10n) }
    static var command: String { String(localized: "home.mcpConnect.command", defaultValue: "Command", bundle: .l10n) }
    static var binary: String { String(localized: "home.mcpConnect.binary", defaultValue: "Binary", bundle: .l10n) }
    static var by: String { String(localized: "home.mcpConnect.by", defaultValue: "By", bundle: .l10n) }
    static var access: String { String(localized: "home.mcpConnect.access", defaultValue: "Access", bundle: .l10n) }
    static var forScope: String { String(localized: "home.mcpConnect.for", defaultValue: "For", bundle: .l10n) }
    static var connect: String { String(localized: "home.mcpConnect.connect", defaultValue: "Connect", bundle: .l10n) }
    static var cancel: String { String(localized: "home.mcpConnect.cancel", defaultValue: "Cancel", bundle: .l10n) }
    static var review: String { String(localized: "home.mcpConnect.review", defaultValue: "Review", bundle: .l10n) }
    static var details: String { String(localized: "home.mcpConnect.details", defaultValue: "Details", bundle: .l10n) }
    static var noSignIn: String { String(localized: "home.mcpConnect.noSignIn", defaultValue: "No sign-in", bundle: .l10n) }
    static func signInWith(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.signInWith", defaultValue: "Sign in with %@", bundle: .l10n), title)
    }
    static func keyNamed(_ name: String) -> String {
        String(format: String(localized: "home.mcpConnect.key", defaultValue: "A key (%@)", bundle: .l10n), name)
    }
    static var keyOptional: String {
        String(localized: "home.mcpConnect.keyOptional", defaultValue: "Optional: it also works without a key.", bundle: .l10n)
    }
    static var keyPrivate: String {
        String(localized: "home.mcpConnect.keyPrivate", defaultValue: "Only cmux sees this key. Agents never do.", bundle: .l10n)
    }
    static var save: String { String(localized: "home.mcpConnect.save", defaultValue: "Save Key", bundle: .l10n) }
    static var skipKey: String { String(localized: "home.mcpConnect.skipKey", defaultValue: "Connect Without a Key", bundle: .l10n) }
    static var signingIn: String {
        String(localized: "home.mcpConnect.signingIn", defaultValue: "Finish signing in on the page that opened.", bundle: .l10n)
    }
    static var connecting: String { String(localized: "home.mcpConnect.connecting", defaultValue: "Connecting…", bundle: .l10n) }
    static func connected(_ title: String, tools: Int, writes: Int) -> String {
        String(format: String(localized: "home.mcpConnect.connected",
                              defaultValue: "%1$@ connected: %2$lld tools, %3$lld can change data", bundle: .l10n),
               title, tools, writes)
    }
    static var declined: String { String(localized: "home.mcpConnect.declined", defaultValue: "Not connected.", bundle: .l10n) }
    static func failed(_ reason: String) -> String {
        String(format: String(localized: "home.mcpConnect.failed", defaultValue: "Couldn’t connect: %@", bundle: .l10n), reason)
    }
    static var flagged: String {
        String(localized: "home.mcpConnect.flagged", defaultValue: "Held: its text tries to give orders", bundle: .l10n)
    }
    static var riskUnverified: String {
        String(localized: "home.mcpConnect.riskUnverified",
               defaultValue: "cmux doesn’t know this server. Connect only if you trust its publisher.", bundle: .l10n)
    }
    static var riskLocal: String {
        String(localized: "home.mcpConnect.riskLocal",
               defaultValue: "This runs a program on this Mac, in a sandbox.", bundle: .l10n)
    }
    static var riskFetches: String {
        String(localized: "home.mcpConnect.riskFetches",
               defaultValue: "The launcher downloads the program each run, so it can change.", bundle: .l10n)
    }
    static var riskIDN: String {
        String(localized: "home.mcpConnect.riskIDN",
               defaultValue: "The address uses international letters that can look like others.", bundle: .l10n)
    }
    static func wantsAccess(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.wantsAccess", defaultValue: "%@ wants to connect", bundle: .l10n), title)
    }
    static func scope(_ scope: McpConnectCard.Scope) -> String {
        switch scope {
        case .chat: String(localized: "home.mcpConnect.scope.chat", defaultValue: "This Chat", bundle: .l10n)
        case .chief: String(localized: "home.mcpConnect.scope.chief", defaultValue: "This Chief", bundle: .l10n)
        case .allChiefs: String(localized: "home.mcpConnect.scope.allChiefs", defaultValue: "All My Chiefs", bundle: .l10n)
        case .agents: String(localized: "home.mcpConnect.scope.agents", defaultValue: "All My Agents", bundle: .l10n)
        case .everywhere: String(localized: "home.mcpConnect.scope.everywhere", defaultValue: "Everywhere", bundle: .l10n)
        }
    }
}
