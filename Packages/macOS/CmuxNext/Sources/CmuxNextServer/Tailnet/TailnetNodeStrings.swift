import Foundation

/// Text of Settings > Accounts > This Mac on Your Tailnet. Keys live in Resources/Tailnet.xcstrings.
nonisolated enum TailnetNodeStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Tailnet", bundle: .module)
    }

    static var title: String { t("tailnet.title", "This Mac on Your Tailnet") }
    static var statusTitle: String { t("tailnet.status", "Status") }
    static var unavailable: String { t("tailnet.unavailable", "This cmux build can't join a tailnet") }
    static var signedOut: String { t("tailnet.signedOut", "Reach this Mac from your other devices") }
    static var signIn: String { t("tailnet.signIn", "Sign In…") }
    static var starting: String { t("tailnet.starting", "Starting…") }
    static var waiting: String { t("tailnet.waiting", "Finish signing in in your browser") }
    static var reopen: String { t("tailnet.reopen", "Reopen") }
    static var cancel: String { t("tailnet.cancel", "Cancel") }
    static var needsApproval: String { t("tailnet.needsApproval", "Waiting for your tailnet admin to approve it") }
    static func failed(_ reason: String) -> String {
        String(format: t("tailnet.failed", "Tailscale stopped: %@"), reason)
    }
    static var addressTitle: String { t("tailnet.address", "Remote Address") }
    static var copy: String { t("tailnet.copy", "Copy") }
    static var pair: String { t("tailnet.pair", "Pair…") }
    static func signedIn(as login: String) -> String {
        String(format: t("tailnet.signedIn", "Signed in as %@"), login)
    }
    static var signedInNoLogin: String { t("tailnet.signedInNoLogin", "Signed in") }
    static var signOut: String { t("tailnet.signOut", "Sign Out") }
    static var limitTitle: String { t("tailnet.limit", "Limit access to your Tailscale account") }
    static var limitHelp: String { t("tailnet.limitHelp", "Only your Tailscale account can connect for now") }
    static var pairHelp: String { t("tailnet.pairHelp", "Run on your other Mac. Works once, for 15 min") }
    static var done: String { t("tailnet.done", "Done") }
    static var pairFailed: String { t("tailnet.pairFailed", "Couldn't make a pairing code. Try again.") }
}

/// The card's text for the App's Settings page (every string localized here).
public nonisolated struct TailnetNodeText: Sendable {
    public init() {}
    public var title: String { TailnetNodeStrings.title }
    public var statusTitle: String { TailnetNodeStrings.statusTitle }
    public var unavailable: String { TailnetNodeStrings.unavailable }
    public var signedOut: String { TailnetNodeStrings.signedOut }
    public var signIn: String { TailnetNodeStrings.signIn }
    public var starting: String { TailnetNodeStrings.starting }
    public var waiting: String { TailnetNodeStrings.waiting }
    public var reopen: String { TailnetNodeStrings.reopen }
    public var cancel: String { TailnetNodeStrings.cancel }
    public var needsApproval: String { TailnetNodeStrings.needsApproval }
    public var addressTitle: String { TailnetNodeStrings.addressTitle }
    public var copy: String { TailnetNodeStrings.copy }
    public var pair: String { TailnetNodeStrings.pair }
    public var signedInNoLogin: String { TailnetNodeStrings.signedInNoLogin }
    public var signOut: String { TailnetNodeStrings.signOut }
    public var limitTitle: String { TailnetNodeStrings.limitTitle }
    public var limitHelp: String { TailnetNodeStrings.limitHelp }
    public var pairHelp: String { TailnetNodeStrings.pairHelp }
    public var done: String { TailnetNodeStrings.done }
    public var pairFailed: String { TailnetNodeStrings.pairFailed }
    public func failed(_ reason: String) -> String { TailnetNodeStrings.failed(reason) }
    public func signedIn(as login: String) -> String { TailnetNodeStrings.signedIn(as: login) }
}
