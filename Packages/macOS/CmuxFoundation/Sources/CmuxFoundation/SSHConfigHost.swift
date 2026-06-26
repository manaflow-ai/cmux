/// A single host entry resolved from an SSH client configuration file
/// (`~/.ssh/config` and any files it `Include`s).
///
/// This backs `cmux ssh list`, which surfaces the user's "external" SSH
/// machines — the hosts defined in their `ssh_config` rather than ones cmux
/// created — so they can be discovered and connected to. Forwarded ports
/// (`LocalForward` / `RemoteForward` / `DynamicForward`) are captured because
/// they are part of what each machine exposes (the motivation behind
/// https://github.com/manaflow-ai/cmux/issues/6774).
///
/// Produced by ``SSHConfigParser``.
public struct SSHConfigHost: Equatable, Sendable, Codable {
    /// The concrete `Host` alias as written in the config (the token you pass
    /// to `ssh`). Wildcard patterns such as `*` or `db-*` are never aliases.
    public var alias: String
    /// Effective `HostName` (the address ssh dials), if configured.
    public var hostName: String?
    /// Effective `User`, if configured.
    public var user: String?
    /// Effective `Port`, if configured.
    public var port: Int?
    /// First effective `IdentityFile`, if configured.
    public var identityFile: String?
    /// Effective `ProxyJump`, if configured.
    public var proxyJump: String?
    /// `LocalForward` specs (e.g. `8080 localhost:80`) that apply, in order.
    public var localForwards: [String]
    /// `RemoteForward` specs that apply, in order.
    public var remoteForwards: [String]
    /// `DynamicForward` specs (e.g. `1080`) that apply, in order.
    public var dynamicForwards: [String]

    /// Creates a host entry. All fields except `alias` default to empty/nil,
    /// matching a host that sets no corresponding `ssh_config` directive.
    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        localForwards: [String] = [],
        remoteForwards: [String] = [],
        dynamicForwards: [String] = []
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.localForwards = localForwards
        self.remoteForwards = remoteForwards
        self.dynamicForwards = dynamicForwards
    }

    /// Whether this host declares any forwarded ports.
    public var forwardsPorts: Bool {
        !localForwards.isEmpty || !remoteForwards.isEmpty || !dynamicForwards.isEmpty
    }
}
