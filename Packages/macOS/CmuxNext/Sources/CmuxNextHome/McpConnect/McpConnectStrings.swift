import Foundation

/// The MCP connect card's user-facing strings (Home's Localizable.xcstrings).
enum McpConnectStrings {
    static func connectTitle(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.title", defaultValue: "Connect %@?", bundle: .localizedModule), title)
    }
    static func asks(_ agent: String) -> String {
        String(format: String(localized: "home.mcpConnect.asks", defaultValue: "%@ asks:", bundle: .localizedModule), agent)
    }
    static var verified: String { String(localized: "home.mcpConnect.verified", defaultValue: "Verified", bundle: .localizedModule) }
    static var unverified: String { String(localized: "home.mcpConnect.unverified", defaultValue: "Unverified", bundle: .localizedModule) }
    static var server: String { String(localized: "home.mcpConnect.server", defaultValue: "Server", bundle: .localizedModule) }
    static var command: String { String(localized: "home.mcpConnect.command", defaultValue: "Command", bundle: .localizedModule) }
    static var binary: String { String(localized: "home.mcpConnect.binary", defaultValue: "Binary", bundle: .localizedModule) }
    static var by: String { String(localized: "home.mcpConnect.by", defaultValue: "By", bundle: .localizedModule) }
    static var access: String { String(localized: "home.mcpConnect.access", defaultValue: "Access", bundle: .localizedModule) }
    static var forScope: String { String(localized: "home.mcpConnect.for", defaultValue: "For", bundle: .localizedModule) }
    static var connect: String { String(localized: "home.mcpConnect.connect", defaultValue: "Connect", bundle: .localizedModule) }
    static var cancel: String { String(localized: "home.mcpConnect.cancel", defaultValue: "Cancel", bundle: .localizedModule) }
    static var review: String { String(localized: "home.mcpConnect.review", defaultValue: "Review", bundle: .localizedModule) }
    static var details: String { String(localized: "home.mcpConnect.details", defaultValue: "Details", bundle: .localizedModule) }
    static var noSignIn: String { String(localized: "home.mcpConnect.noSignIn", defaultValue: "No sign-in", bundle: .localizedModule) }
    static func signInWith(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.signInWith", defaultValue: "Sign in with %@", bundle: .localizedModule), title)
    }
    static func keyNamed(_ name: String) -> String {
        String(format: String(localized: "home.mcpConnect.key", defaultValue: "A key (%@)", bundle: .localizedModule), name)
    }
    static var keyOptional: String {
        String(localized: "home.mcpConnect.keyOptional", defaultValue: "Optional: it also works without a key.", bundle: .localizedModule)
    }
    static var keyPrivate: String {
        String(localized: "home.mcpConnect.keyPrivate", defaultValue: "Only cmux sees this key. Agents never do.", bundle: .localizedModule)
    }
    static var save: String { String(localized: "home.mcpConnect.save", defaultValue: "Save Key", bundle: .localizedModule) }
    static var skipKey: String { String(localized: "home.mcpConnect.skipKey", defaultValue: "Connect Without a Key", bundle: .localizedModule) }
    static var signingIn: String {
        String(localized: "home.mcpConnect.signingIn", defaultValue: "Finish signing in on the page that opened.", bundle: .localizedModule)
    }
    static var connecting: String { String(localized: "home.mcpConnect.connecting", defaultValue: "Connecting…", bundle: .localizedModule) }
    static func connected(_ title: String, tools: Int, writes: Int) -> String {
        String(format: String(localized: "home.mcpConnect.connected",
                              defaultValue: "%1$@ connected: %2$lld tools, %3$lld can change data", bundle: .localizedModule),
               title, tools, writes)
    }
    static var declined: String { String(localized: "home.mcpConnect.declined", defaultValue: "Not connected.", bundle: .localizedModule) }
    static func failed(_ reason: String) -> String {
        String(format: String(localized: "home.mcpConnect.failed", defaultValue: "Couldn’t connect: %@", bundle: .localizedModule), reason)
    }
    static var flagged: String {
        String(localized: "home.mcpConnect.flagged", defaultValue: "Held: its text tries to give orders", bundle: .localizedModule)
    }
    static var riskUnverified: String {
        String(localized: "home.mcpConnect.riskUnverified",
               defaultValue: "cmux doesn’t know this server. Connect only if you trust its publisher.", bundle: .localizedModule)
    }
    static var riskLocal: String {
        String(localized: "home.mcpConnect.riskLocal",
               defaultValue: "This runs a program on this Mac, in a sandbox.", bundle: .localizedModule)
    }
    static var riskFetches: String {
        String(localized: "home.mcpConnect.riskFetches",
               defaultValue: "The launcher downloads the program each run, so it can change.", bundle: .localizedModule)
    }
    static var riskIDN: String {
        String(localized: "home.mcpConnect.riskIDN",
               defaultValue: "The address uses international letters that can look like others.", bundle: .localizedModule)
    }
    static func wantsAccess(_ title: String) -> String {
        String(format: String(localized: "home.mcpConnect.wantsAccess", defaultValue: "%@ wants to connect", bundle: .localizedModule), title)
    }
    static func scope(_ scope: McpConnectCard.Scope) -> String {
        switch scope {
        case .chat: String(localized: "home.mcpConnect.scope.chat", defaultValue: "This Chat", bundle: .localizedModule)
        case .chief: String(localized: "home.mcpConnect.scope.chief", defaultValue: "This Chief", bundle: .localizedModule)
        case .allChiefs: String(localized: "home.mcpConnect.scope.allChiefs", defaultValue: "All My Chiefs", bundle: .localizedModule)
        case .agents: String(localized: "home.mcpConnect.scope.agents", defaultValue: "All My Agents", bundle: .localizedModule)
        case .everywhere: String(localized: "home.mcpConnect.scope.everywhere", defaultValue: "Everywhere", bundle: .localizedModule)
        }
    }
}
