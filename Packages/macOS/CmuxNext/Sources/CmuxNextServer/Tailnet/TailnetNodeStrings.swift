import Foundation

/// Text of Settings > Accounts > This Mac on Your Tailnet. Keys live in Resources/Tailnet.xcstrings.
public nonisolated enum TailnetNodeStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Tailnet", bundle: .module)
    }

    public static var title: String { t("tailnet.title", "This Mac on Your Tailnet") }
    public static var statusTitle: String { t("tailnet.status", "Status") }
    public static var unavailable: String { t("tailnet.unavailable", "This cmux build can't join a tailnet") }
    public static var signedOut: String { t("tailnet.signedOut", "Reach this Mac from your other devices") }
    public static var signIn: String { t("tailnet.signIn", "Sign In…") }
    public static var starting: String { t("tailnet.starting", "Starting…") }
    public static var waiting: String { t("tailnet.waiting", "Finish signing in in your browser") }
    public static var reopen: String { t("tailnet.reopen", "Reopen") }
    public static var cancel: String { t("tailnet.cancel", "Cancel") }
    public static var needsApproval: String { t("tailnet.needsApproval", "Waiting for your tailnet admin to approve it") }
    public static func failed(_ reason: String) -> String {
        String(format: t("tailnet.failed", "Tailscale stopped: %@"), reason)
    }
    public static var addressTitle: String { t("tailnet.address", "Remote Address") }
    public static var copy: String { t("tailnet.copy", "Copy") }
    public static var pair: String { t("tailnet.pair", "Pair…") }
    public static func signedIn(as login: String) -> String {
        String(format: t("tailnet.signedIn", "Signed in as %@"), login)
    }
    public static var signedInNoLogin: String { t("tailnet.signedInNoLogin", "Signed in") }
    public static var signOut: String { t("tailnet.signOut", "Sign Out") }
    public static var limitTitle: String { t("tailnet.limit", "Limit access to your Tailscale account") }
    public static var limitHelp: String { t("tailnet.limitHelp", "Only your Tailscale account can connect for now") }
    public static var pairHelp: String { t("tailnet.pairHelp", "Run on your other Mac. Works once, for 15 min") }
    public static var done: String { t("tailnet.done", "Done") }
    public static var pairFailed: String { t("tailnet.pairFailed", "Couldn't make a pairing code. Try again.") }
}
