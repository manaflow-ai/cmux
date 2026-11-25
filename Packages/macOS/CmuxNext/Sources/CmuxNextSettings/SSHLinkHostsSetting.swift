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
    public init() {}

    /// The entries in `root` as written; a value that is not a list of strings allows none.
    /// Rust reads it (`link_rules.ssh_hosts`).
    public func hosts(in root: JSONValue) -> [String] {
        let reply = SettingsRust.answer("link_rules.ssh_hosts", .object(["root": root]))
        return reply["hosts"]?.arrayValue?.compactMap(\.stringValue) ?? Self.fallback
    }
}

extension SettingsController {
    /// Adds `host` to `ssh.linkAllowedHosts` (the confirmation's "Always allow this host") as
    /// the person's write; does nothing when the list already has it.
    public func allowSSHLinkHost(_ host: String) async throws {
        let reply = SettingsRust.answer("link_rules.ssh_allow", .object(["root": snapshot.root, "host": .string(host)]))
        guard let hosts = reply["hosts"] else { return }
        try await setSetting(at: SSHLinkHostsSetting.configPath, to: hosts, by: .user)
    }
}
