/// The person's one-time consent to use the Codex sign-in already on this Mac for the Cloud machines
/// they own (Leo, 2026-11-05: "claude/codex/antigravity/cursor/muse and those subscriptions should all
/// be detectable / many many existing apps can do this"). In cmux.json:
///
/// ```jsonc
/// "cloud": { "useMyCodexLoginOnMyCloudMachines": true }
/// ```
///
/// Yes: the Mac reads its own Codex access token (never the refresh token) and gives the machine only
/// that short-lived access, renewing it from the Mac, so no device sign-in shows and the Mac's own
/// Codex sign-in is never refreshed by anyone else. Missing: asked once, the first time a machine
/// would need a Codex sign-in. Only the person sets it, in every build: agents are refused (privacy),
/// and any managed source makes it no (``CloudLoginCopyConsentSetting``'s rule).
public nonisolated struct CloudCodexSignInConsentSetting: Sendable {
    public static let path = ["cloud", "useMyCodexLoginOnMyCloudMachines"]
    public static let key = path.joined(separator: ".")

    public init() {}

    /// The person's answer: nil when never asked, else yes or no. Only the person's own cmux.json says yes.
    public func consent(file: JSONValue, effective: JSONValue, managed: Bool) -> Bool? {
        CloudLoginCopyConsentSetting.consent(at: Self.path, file: file, effective: effective, managed: managed)
    }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                path, section: .machines, group: SettingsText.keyed("settings.group.cloudWorkspaces", "Cloud Workspaces"),
                title: SettingsText.keyed("settings.cloud.useMyCodexLogin", "Use My Codex Login on My Own Cloud Machines"),
                help: SettingsText.keyed("settings.cloud.useMyCodexLogin.help",
                                         "Gives Cloud machines you own short-lived access from the Codex sign-in on this Mac, so their chats start signed in. The machine never gets your refresh token, and cmux never stores it. Off: a machine asks for a Codex sign-in instead."),
                kind: .toggle, default: .bool(false),
                keywords: ["cloud", "codex", "chatgpt", "login", "sign in", "token", "credential", "machine", "consent"]
            ),
        ]
    }
}
