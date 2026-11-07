/// The person's one-time consent to copy their own Claude login from this Mac to the Cloud machines
/// they own, in a Release build (Leo, 2026-11-02: "Consent first. It's on only after a clear one-time
/// prompt: 'use my Claude login on my own Cloud machines'"). In cmux.json:
///
/// ```jsonc
/// "cloud": { "useMyClaudeLoginOnMyCloudMachines": true }
/// ```
///
/// Missing: never asked, so the first Cloud chat that would get the login asks once. The prompt's
/// answer is written here; Settings > Machines turns it off (taken back) or on again. Only the
/// person sets it: agents are refused (privacy). DEV and NIGHTLY builds copy the login without it.
public nonisolated struct CloudLoginCopyConsentSetting: Sendable {
    public static let path = ["cloud", "useMyClaudeLoginOnMyCloudMachines"]
    public static let key = path.joined(separator: ".")

    public init() {}

    /// The person's answer: nil when never asked (or a non-boolean value), else yes or no. Only the
    /// person's own cmux.json (`file`) can say yes. A key any managed source holds (`managed`: MDM,
    /// a team policy, `defaults write`) is no whatever its value, since an organization or a
    /// script never consents for the person; an effective `false` is no too.
    public func consent(file: JSONValue, effective: JSONValue, managed: Bool) -> Bool? {
        Self.consent(at: Self.path, file: file, effective: effective, managed: managed)
    }

    /// The rule every login consent key shares (``CloudCodexSignInConsentSetting`` too).
    static func consent(at path: [String], file: JSONValue, effective: JSONValue, managed: Bool) -> Bool? {
        if managed || effective.value(at: path)?.boolValue == false { return false }
        return file.value(at: path)?.boolValue
    }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                path, section: .machines, group: SettingsText.keyed("settings.group.cloudWorkspaces", "Cloud Workspaces"),
                title: SettingsText.keyed("settings.cloud.useMyClaudeLogin", "Use My Claude Login on My Own Cloud Machines"),
                help: SettingsText.keyed("settings.cloud.useMyClaudeLogin.help",
                                         "Copies your own Claude login from this Mac to Cloud machines you own, so their chats start signed in. Never to team or shared machines, and cmux never stores it. Off: each machine offers Sign in to Claude instead."),
                kind: .toggle, default: .bool(false),
                keywords: ["cloud", "claude", "login", "sign in", "token", "credential", "machine", "consent", "copy"]
            ),
        ]
    }
}
