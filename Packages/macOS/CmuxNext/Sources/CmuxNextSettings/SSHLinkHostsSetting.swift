/// `ssh.linkAllowedHosts` in cmux-next.json: the hosts an `ssh://` link from another app opens
/// without asking, written by the confirmation's "Always allow this host" and listed in
/// Settings > Privacy and Security > SSH Links, where a host is removed again:
///
/// ```jsonc
/// "ssh": { "linkAllowedHosts": ["build.example.com", "fe80::1"] }
/// ```
///
/// One entry per host, whatever user or port a later link names: a host is the machine the
/// person said they trust. The link gate compares entries by `SSHLinkTarget.trustKey`.
public nonisolated struct SSHLinkHostsSetting: Sendable {
    public static let configPath = ["ssh", "linkAllowedHosts"]

    public init() {}

    /// The entries in `root` as written; a value that is not a list of strings allows none.
    public func hosts(in root: JSONValue) -> [String] {
        guard case .array(let entries)? = root.value(at: Self.configPath) else { return [] }
        return entries.compactMap(\.stringValue)
    }

    static var descriptor: SettingDescriptor {
        SettingDescriptor(
            configPath, section: .machines,
            group: SettingsText.keyed("settings.group.sshLinks", "SSH Links"),
            title: SettingsText.keyed("settings.machines.sshLinkHosts", "Always Allowed SSH Link Hosts"),
            help: SettingsText.keyed("settings.machines.sshLinkHosts.help",
                                     "An ssh:// link from another app connects to these hosts without asking. Remove a host to be asked again. Saved machines and acpmux peers never ask."),
            kind: .stringList, default: .array([]),
            keywords: ["ssh", "link", "url", "host", "trust", "allow", "always", "machine", "security"]
        )
    }
}

extension SettingsController {
    /// Adds `host` to `ssh.linkAllowedHosts` (the confirmation's "Always allow this host") as
    /// the person's write; does nothing when the list already has it.
    public func allowSSHLinkHost(_ host: String) async throws {
        let current = SSHLinkHostsSetting().hosts(in: snapshot.root)
        guard !host.isEmpty, !current.contains(host) else { return }
        try await setSetting(at: SSHLinkHostsSetting.configPath, to: .array((current + [host]).map(JSONValue.string)), by: .user)
    }
}
