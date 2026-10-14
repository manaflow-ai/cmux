internal import Darwin
internal import CryptoKit
internal import Foundation

/// Merges cmux's native-SSH connection-sharing defaults without replacing
/// caller-provided OpenSSH control options.
///
/// The default `ControlPath` is stable for the local user and relies on
/// OpenSSH's `%C` expansion to separate effective `(user, host, port)`
/// endpoints. Workspace relay ports deliberately do not participate in the
/// path: reverse forwards are individual channels on the shared master.
///
/// `%C` ignores how a connection reaches and authenticates to that endpoint.
/// A route with security-relevant options (proxy, identity, agent, host-key
/// policy and similar) therefore gets its own socket, named by a digest of
/// its resolved route, or shares nothing when no resolved route is known.
///
/// The sockets live in `~/.cmux/ssh`. OpenSSH trusts whatever socket is at
/// `ControlPath`, so when no directory only this user can write to is
/// available, cmux adds no sharing defaults and the user's SSH configuration
/// applies as is.
public struct SSHConnectionSharingOptions: Sendable {
    /// Local uid that names cmux's authentication lock files.
    public let userID: Int
    /// Directory holding cmux's control sockets, or `nil` when cmux shares
    /// no connections because no private directory is available.
    public let controlSocketDirectoryPath: String?
    private let authenticationLockDirectory: URL
    /// Private option key carrying a resolved route's identity, or `true`
    /// when the route is sensitive but no identity could be resolved.
    private static let routeSensitiveMarkerKey = "__cmux_route_sensitive"
    /// Resolved `ssh -G` keys naming the endpoint a route reaches. `proxyjump`
    /// is here because older OpenSSH releases leave it out of `%C`.
    ///
    /// `host` is the destination as typed. `ssh -G` prints `ProxyCommand`,
    /// `IdentityFile`, `CertificateFile`, `LocalCommand` and
    /// `KnownHostsCommand` without expanding their tokens, and `%n` (and `%k`
    /// without a `HostKeyAlias`) expand to that destination when the
    /// connection runs. Two aliases can therefore print identical routes that
    /// reach different proxies or keys. Scanning values for those tokens would
    /// have to track `%%` escapes and future tokens, so the alias always joins
    /// the identity; aliases then never share a route-specific master, which
    /// only costs an extra connection.
    private static let routeEndpointKeys: Set<String> = ["host", "user", "hostname", "port", "proxyjump"]
    /// Options that change how a connection reaches or authenticates to its
    /// endpoint, or what a session on the master can do there. `%C` ignores
    /// all of them, so routes that differ in one must not share a master.
    private static let routeSensitiveKeys: Set<String> = [
        "proxycommand", "proxyjump", "identityfile", "certificatefile",
        "hostkeyalias", "hostkeyalgorithms", "hostbasedacceptedalgorithms",
        "pubkeyacceptedalgorithms", "userknownhostsfile", "globalknownhostsfile",
        "stricthostkeychecking", "checkhostip", "verifyhostkeydns",
        "updatehostkeys", "nohostauthenticationforlocalhost", "knownhostscommand",
        "revokedhostkeys", "visualhostkey", "hashknownhosts",
        "casignaturealgorithms", "requiredrsasize", "kexalgorithms", "ciphers", "macs",
        "preferredauthentications", "canonicalizehostname", "canonicalizemaxdots",
        "canonicalizepermittedcnames", "remotecommand", "localcommand",
        "permitlocalcommand", "matchfinal", "sendenv", "setenv",
        "addressfamily", "bindaddress", "bindinterface", "localaddress",
        "gssapiauthentication", "gssapikexalgorithms", "gssapiserveridentity",
        "gssapidelegatecredentials", "kerberosauthentication", "kerberosorlocalpasswd",
        // The master's agent and key sources authenticate the connection every
        // multiplexed session rides, and agent forwarding exposes that agent
        // to the remote host.
        "identityagent", "identitiesonly", "pkcs11provider", "securitykeyprovider",
        "forwardagent", "forwardx11trusted", "proxyusefdpass",
    ]

    /// Creates an option merger for the current local user, creating
    /// `~/.cmux/ssh` if needed.
    public init() {
        let userID = Int(getuid())
        self.userID = userID
        self.controlSocketDirectoryPath = SSHControlSocketDirectory.prepare(
            home: NSHomeDirectory(),
            userID: userID
        )
        self.authenticationLockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Creates an option merger with injected paths, without touching the
    /// file system.
    ///
    /// - Parameters:
    ///   - userID: Local uid used in lock file names.
    ///   - controlSocketDirectoryPath: A directory only `userID` can write to,
    ///     or `nil` to share no connections. A path OpenSSH would expand, or
    ///     one too long to hold a socket, also shares no connections.
    ///   - authenticationLockDirectoryPath: User-private directory for
    ///     authentication locks, or `nil` for the per-user temporary directory.
    public init(
        userID: Int,
        controlSocketDirectoryPath: String?,
        authenticationLockDirectoryPath: String? = nil
    ) {
        self.userID = userID
        self.controlSocketDirectoryPath = controlSocketDirectoryPath.flatMap {
            SSHControlSocketDirectory.isUsable($0) ? $0 : nil
        }
        self.authenticationLockDirectory = URL(
            fileURLWithPath: authenticationLockDirectoryPath ?? NSTemporaryDirectory(),
            isDirectory: true
        )
    }

    /// The cmux-owned, host-stable OpenSSH control-socket template, or `nil`
    /// when cmux shares no connections.
    public var defaultControlPath: String? {
        controlSocketDirectoryPath.map { "\($0)/%C" }
    }

    /// A shell `case` pattern matching only the sockets ``defaultControlPath``
    /// expands to, or `nil` when cmux shares no connections.
    public var resolvedControlPathShellPattern: String? {
        controlSocketDirectoryPath.map {
            "'\($0)'/" + String(repeating: "[0-9a-f]", count: SSHControlSocketDirectory.socketNameLength)
        }
    }

    /// User-private directory used for cross-process ControlMaster locks.
    public var controlMasterLockDirectoryPath: String {
        authenticationLockDirectory.path
    }

    /// Adds missing sharing defaults while preserving every supplied value.
    ///
    /// A caller that disables `ControlMaster` keeps a standalone connection;
    /// cmux does not add `ControlPersist` or `ControlPath` in that case. A
    /// custom `ControlPath` or `ControlPersist` remains authoritative, except
    /// that an older cmux's socket in shared `/tmp` becomes cmux's private one.
    ///
    /// - Parameter options: OpenSSH `-o` values in caller precedence order.
    /// - Returns: Trimmed options plus only the missing cmux defaults.
    public func mergingDefaults(into options: [String]) -> [String] {
        mergingDefaults(into: options, userConfiguredControlOptions: nil, routeSensitiveOptions: [])
    }

    /// Adds sharing defaults while honoring effective control settings from
    /// the user's SSH configuration.
    ///
    /// Explicit caller options retain highest precedence per key. Independently
    /// configured host control settings fill the remaining keys instead of
    /// installing cmux's socket.
    ///
    /// - Parameters:
    ///   - options: Explicit OpenSSH `-o` values.
    ///   - userConfiguredControlOptions: Effective custom values parsed by
    ///     ``userConfiguredControlOptions(fromSSHConfigOutput:explicitOptions:)``.
    ///   - routeSensitiveOptions: Values that make the route-specific socket
    ///     necessary when a route identifier is available.
    ///   - routeIdentifier: Stable opaque identity for the complete route, such
    ///     as ``routeIdentifier(fromSSHConfigOutput:)``. Route-sensitive
    ///     options use a private socket derived from this value, or else from
    ///     the route resolved into `userConfiguredControlOptions`; without
    ///     either they remain unshared.
    /// - Returns: Effective explicit options for native SSH commands.
    public func mergingDefaults(
        into options: [String],
        userConfiguredControlOptions: [String]? = nil,
        routeSensitiveOptions: [String] = [],
        routeIdentifier: String? = nil
    ) -> [String] {
        let resolver = SSHAgentSocketResolver()
        let optionRouteMarkerValue = resolver.optionValue(
            named: Self.routeSensitiveMarkerKey,
            in: options
        )
        let routeMarkerValue = resolver.optionValue(
            named: Self.routeSensitiveMarkerKey,
            in: userConfiguredControlOptions ?? []
        )
        let routeSensitive = !routeSensitiveOptions.isEmpty
            || options.contains { option in
                guard let key = resolver.optionKey(option) else { return false }
                return Self.routeSensitiveKeys.contains(key)
            }
            || optionRouteMarkerValue != nil
            || routeMarkerValue != nil
        // A caller's identity wins; otherwise use the route `ssh -G` resolved.
        // The `true` placeholder means no identity is known.
        let effectiveRouteIdentifier = routeIdentifier
            ?? optionRouteMarkerValue.flatMap { Self.isRouteDigest($0) ? $0 : nil }
            ?? routeMarkerValue.flatMap { Self.isRouteDigest($0) ? $0 : nil }
        var merged = options.compactMap { option -> String? in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, resolver.optionKey(trimmed) != Self.routeSensitiveMarkerKey else { return nil }
            return trimmed
        }
        let controlKeys = ["ControlMaster", "ControlPath", "ControlPersist"]
        if let userConfiguredControlOptions {
            for key in controlKeys where !resolver.hasOptionKey(merged, key: key) {
                if let effectiveOption = userConfiguredControlOptions.first(where: {
                    resolver.optionKey($0) == key.lowercased()
                }) {
                    merged.append(effectiveOption)
                }
            }
        }
        // Another local user can plant a socket in /tmp, and OpenSSH connects
        // to one at ControlPath even with ControlMaster=no.
        let suppliedControlPath = resolver.optionValue(named: "ControlPath", in: merged)
        let migratedSharedTemporaryControlPath = suppliedControlPath.map(isSharedTemporaryControlPath) == true
        if migratedSharedTemporaryControlPath {
            let replacement = defaultControlPath ?? "none"
            merged = merged.map { option in
                guard resolver.optionKey(option) == "controlpath" else { return option }
                return "ControlPath=\(replacement)"
            }
        }
        guard let defaultControlPath else { return merged }
        // `%C` distinguishes only user, host and port. A route with a custom
        // proxy, identity, host-key alias/policy or remote command must not
        // share cmux's default master with another route to the same endpoint.
        let hasCustomControlPath = resolver.hasOptionKey(merged, key: "ControlPath")
            || userConfiguredControlOptions?.contains(where: { resolver.optionKey($0) == "controlpath" }) == true
        let hasUserManagedControlPath = hasCustomControlPath && !migratedSharedTemporaryControlPath
        if routeSensitive && !hasUserManagedControlPath {
            // Persist the route decision in the options that later SSH
            // helpers carry forward. A private marker is intentionally not
            // enough: callers serialize and re-merge these options after
            // this function returns, so a marker-only result would be lost
            // and the next merge would install the shared `%C` socket.
            let controlMaster = resolver.optionValue(named: "ControlMaster", in: merged)
            if isDisabled(controlMaster) {
                if migratedSharedTemporaryControlPath {
                    merged = merged.map { option in
                        resolver.optionKey(option) == "controlpath"
                            ? "ControlPath=none"
                            : option
                    }
                } else if !resolver.hasOptionKey(merged, key: "ControlPath") {
                    merged.append("ControlPath=none")
                }
                return merged
            }
            if let effectiveRouteIdentifier,
               let routeControlPath = routeSpecificControlPath(for: effectiveRouteIdentifier) {
                if controlMaster == nil {
                    merged.append("ControlMaster=auto")
                }
                if !resolver.hasOptionKey(merged, key: "ControlPersist") {
                    merged.append("ControlPersist=600")
                }
                if migratedSharedTemporaryControlPath {
                    merged = merged.map { option in
                        resolver.optionKey(option) == "controlpath"
                            ? "ControlPath=\(routeControlPath)"
                            : option
                    }
                } else {
                    merged.append("ControlPath=\(routeControlPath)")
                }
            } else {
                if controlMaster == nil {
                    merged.append("ControlMaster=no")
                }
                if migratedSharedTemporaryControlPath {
                    merged = merged.map { option in
                        resolver.optionKey(option) == "controlpath"
                            ? "ControlPath=none"
                            : option
                    }
                } else if !resolver.hasOptionKey(merged, key: "ControlPath") {
                    merged.append("ControlPath=none")
                }
            }
            return merged
        }
        let controlMaster = resolver.optionValue(
            named: "ControlMaster",
            in: merged
        )
        let controlMasterDisabled = isDisabled(controlMaster)
        if controlMaster == nil {
            merged.append("ControlMaster=auto")
        }
        if !controlMasterDisabled {
            if !resolver.hasOptionKey(merged, key: "ControlPersist") {
                merged.append("ControlPersist=600")
            }
            if !resolver.hasOptionKey(merged, key: "ControlPath") {
                merged.append("ControlPath=\(defaultControlPath)")
            }
        }
        return merged
    }

    /// Returns a stable identity for the complete route `ssh -G` resolved.
    ///
    /// The identity covers the destination as typed (`host`), the endpoint
    /// (`user`, `hostname`, `port`, `proxyjump`) and every security-relevant
    /// option in OpenSSH's resolved form, so explicit `-o`/`-i` values and
    /// ssh_config values count alike. Different aliases get different
    /// identities because `ssh -G` leaves alias-dependent tokens such as `%n`
    /// unexpanded. Pass it as
    /// `routeIdentifier` to
    /// ``mergingDefaults(into:userConfiguredControlOptions:routeSensitiveOptions:routeIdentifier:)``.
    ///
    /// - Parameter output: Standard output from `ssh -G <destination>` run
    ///   with the caller's explicit options.
    /// - Returns: A lowercase hex digest, or `nil` when the output names no host.
    public func routeIdentifier(fromSSHConfigOutput output: String) -> String? {
        var entries: [(key: String, value: String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard Self.routeEndpointKeys.contains(key) || Self.routeSensitiveKeys.contains(key) else {
                continue
            }
            entries.append((key, parts[1].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard entries.contains(where: { $0.key == "hostname" && !$0.value.isEmpty }) else {
            return nil
        }
        // Sort by key only: repeated keys such as `identityfile` keep the
        // order OpenSSH tries them in.
        let canonical = entries.enumerated()
            .sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }
            .map { "\($0.element.key) \($0.element.value)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(("cmux-ssh-route-v1\n" + canonical).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Returns an opaque route marker that can cross the CLI-to-app boundary.
    ///
    /// The marker carries only the digest of OpenSSH's resolved configuration;
    /// it never serializes a proxy command, socket path, or credential.
    public func routeSensitiveOption(for routeIdentifier: String) -> String? {
        guard Self.isRouteDigest(routeIdentifier) else { return nil }
        return "\(Self.routeSensitiveMarkerKey)=\(routeIdentifier)"
    }

    /// Reads the opaque route marker from serialized SSH options.
    public func routeSensitiveIdentifier(in options: [String]) -> String? {
        let resolver = SSHAgentSocketResolver(environment: [:])
        guard let value = resolver.optionValue(named: Self.routeSensitiveMarkerKey, in: options),
              Self.isRouteDigest(value) else {
            return nil
        }
        return value
    }

    /// Removes only the cmux-owned control socket generated before a CLI-to-app
    /// TUI handoff and carries its opaque route identity when needed. Caller
    /// supplied control paths remain authoritative and are forwarded unchanged.
    ///
    /// The returned values are durable SSH options; the private route marker is
    /// consumed by ``mergingDefaults(into:userConfiguredControlOptions:routeSensitiveOptions:routeIdentifier:)``
    /// before any OpenSSH process is launched.
    public func optionsForTUIHandoff(
        _ options: [String],
        routeIdentifier: String? = nil
    ) -> [String] {
        let resolver = SSHAgentSocketResolver(environment: [:])
        var tuiOptions = options
        let generatedControlPath = cmuxOwnedControlPath(in: tuiOptions)
        if generatedControlPath != nil {
            tuiOptions.removeAll { resolver.optionKey($0) == "controlpath" }
        }
        // A route digest is needed only when the generated socket was already
        // route-specific. The normal `%C` socket is recomputed by the app;
        // carrying its digest would unnecessarily split ordinary connections.
        if let routeIdentifier, generatedControlPath?.contains("%") == false,
           let routeMarker = routeSensitiveOption(for: routeIdentifier) {
            tuiOptions.append(routeMarker)
        }
        return tuiOptions
    }

    /// Whether `value` is an identity from ``routeIdentifier(fromSSHConfigOutput:)``.
    private static func isRouteDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Returns a private, deterministic socket path for one route identity.
    ///
    /// The name has the length and alphabet of a `%C` expansion, so it fits
    /// the same `sun_path` budget and every recognizer of cmux-owned sockets
    /// (Swift checks, shell `case` patterns, lock and broker keys) accepts it.
    private func routeSpecificControlPath(for routeIdentifier: String) -> String? {
        guard let controlSocketDirectoryPath,
              !routeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(routeIdentifier.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(controlSocketDirectoryPath)/\(digest)"
    }

    /// Parses custom effective control settings from `ssh -G` output.
    ///
    /// OpenSSH prints built-in defaults even when the user's config contains
    /// no control directives. That default triple returns `nil`, allowing
    /// cmux sharing defaults. Any non-default value returns all three
    /// effective settings so subsequent commands behave exactly like the
    /// resolved user configuration.
    ///
    /// - Parameter output: Standard output from `ssh -G <destination>` before
    ///   cmux control options are added.
    /// - Returns: Effective custom `-o` values, or `nil` for OpenSSH defaults.
    public func userConfiguredControlOptions(fromSSHConfigOutput output: String) -> [String]? {
        userConfiguredControlOptions(fromSSHConfigOutput: output, explicitOptions: [])
    }

    /// Parses resolved host control settings with the explicit caller options
    /// that were included in the `ssh -G` invocation.
    ///
    /// Explicit values do not prove host customization: OpenSSH includes them in
    /// its output and normalizes `ControlPersist=0` to `yes`. A custom value on
    /// another control key still preserves the host's full effective settings,
    /// with explicit options retaining precedence when merged.
    ///
    /// - Parameters:
    ///   - output: Effective configuration reported by OpenSSH.
    ///   - explicitOptions: Caller-provided `-o` values included in that output.
    /// - Returns: Effective custom host control settings, or `nil` for defaults.
    public func userConfiguredControlOptions(
        fromSSHConfigOutput output: String,
        explicitOptions: [String]
    ) -> [String]? {
        userConfiguredControlOptions(
            fromSSHConfigOutput: output,
            baselineSSHConfigOutput: nil,
            explicitOptions: explicitOptions
        )
    }

    /// Parses resolved host control settings against OpenSSH's built-in
    /// defaults, taken from a `-F /dev/null` baseline when one is available.
    ///
    /// `ssh -G` prints defaults too, and omits unset keys such as
    /// `ControlPath`, so an absent key means the built-in default on both
    /// sides. A host setting counts as configured only when its effective value
    /// differs from the baseline. OpenSSH versions that normalize a host
    /// `ControlMaster no` to the default `false` report no difference, and
    /// cmux sharing stays enabled for them.
    public func userConfiguredControlOptions(
        fromSSHConfigOutput output: String,
        baselineSSHConfigOutput: String?,
        explicitOptions: [String]
    ) -> [String]? {
        // OpenSSH omits unset keys, so an absent key is its built-in default.
        let builtInDefaults = [
            "controlmaster": "false",
            "controlpath": "none",
            "controlpersist": "no",
        ]
        let values = builtInDefaults.merging(
            controlConfigurationValues(fromSSHConfigOutput: output)
        ) { _, reported in reported }
        let baselineValues = builtInDefaults.merging(
            baselineSSHConfigOutput.map(controlConfigurationValues(fromSSHConfigOutput:)) ?? [:]
        ) { _, reported in reported }
        let resolver = SSHAgentSocketResolver()
        let hasCustomValue = builtInDefaults.keys.contains { key in
            guard !resolver.hasOptionKey(explicitOptions, key: key) else { return false }
            return values[key]?.lowercased() != baselineValues[key]?.lowercased()
        }
        let routeSensitive = Self.routeSensitiveKeys.contains { key in
            values[key]?.lowercased() != baselineValues[key]?.lowercased()
        }
        guard hasCustomValue || routeSensitive else { return nil }
        var result: [String] = []
        if hasCustomValue {
            result += [
                "ControlMaster=\(values["controlmaster"] ?? "false")",
                "ControlPath=\(values["controlpath"] ?? "none")",
                "ControlPersist=\(values["controlpersist"] ?? "no")",
            ]
        }
        if routeSensitive {
            let identity = routeIdentifier(fromSSHConfigOutput: output) ?? "true"
            result.append("\(Self.routeSensitiveMarkerKey)=\(identity)")
        }
        return result
    }

    private func controlConfigurationValues(fromSSHConfigOutput output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard ["controlmaster", "controlpath", "controlpersist"].contains(key)
                || Self.routeSensitiveKeys.contains(key) else {
                continue
            }
            values[key] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    /// Returns the configured `ControlPath` when it is cmux's template or a
    /// socket that template expands to.
    ///
    /// Sockets an older cmux left in shared `/tmp` are not cmux-owned: another
    /// local user could have created them, so cmux never checks or removes them.
    ///
    /// - Parameter options: OpenSSH `-o` values to inspect.
    /// - Returns: The cmux-owned path, or `nil` for user-managed paths.
    public func cmuxOwnedControlPath(in options: [String]) -> String? {
        let resolver = SSHAgentSocketResolver()
        guard let defaultControlPath, let controlSocketDirectoryPath else { return nil }
        guard !isDisabled(resolver.optionValue(
            named: "ControlMaster",
            in: options
        )) else {
            return nil
        }
        guard let rawPath = resolver.optionValue(
            named: "ControlPath",
            in: options
        ) else {
            return nil
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path == defaultControlPath ||
                isResolvedControlPath(path, in: controlSocketDirectoryPath) else {
            return nil
        }
        return path
    }

    /// Returns a deterministic local advisory-lock path for foreground
    /// authentication against a cmux-owned control socket.
    ///
    /// Holding this lock only around the short `ssh ... true` master warmup
    /// makes concurrent workspaces queue behind the first agent prompt. Once
    /// that command returns, later callers reuse the ready master. Custom
    /// control paths return `nil` and remain entirely user-managed.
    ///
    /// - Parameters:
    ///   - destination: SSH destination or config alias.
    ///   - port: Explicit SSH port, when supplied.
    ///   - options: Effective OpenSSH `-o` values.
    /// The lock lives in Darwin's user-private temporary directory rather
    /// than shared `/tmp`, so shell redirection cannot follow a symlink planted
    /// by another local user before the foreground-auth locker opens it.
    ///
    /// - Returns: A user-private temporary lock path, or `nil` for a user-managed socket.
    public func foregroundAuthenticationLockPath(
        destination: String,
        port: Int?,
        options: [String]
    ) -> String? {
        guard let controlPath = cmuxOwnedControlPath(in: options) else { return nil }
        let fingerprint = controlPath.contains("%")
            ? "\(destination.trimmingCharacters(in: .whitespacesAndNewlines))\u{1f}\(port.map(String.init) ?? "")"
            : controlPath
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fingerprint.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let unpaddedHash = String(hash, radix: 16, uppercase: false)
        let paddedHash = String(repeating: "0", count: max(0, 16 - unpaddedHash.count)) + unpaddedHash
        return authenticationLockDirectory
            .appendingPathComponent("cmux-ssh-\(userID)-auth-\(paddedHash).lock", isDirectory: false)
            .path
    }

    /// Returns the shared authentication lock for one exact cmux-owned socket.
    ///
    /// Unlike ``foregroundAuthenticationLockPath(destination:port:options:)``,
    /// this identity is stable across different SSH aliases that OpenSSH
    /// expands to the same `ControlPath`.
    public func resolvedControlMasterAuthenticationLockPath(
        controlPath: String
    ) -> String? {
        guard let basename = resolvedControlPathBasename(controlPath) else {
            return nil
        }
        return authenticationLockDirectory
            .appendingPathComponent(
                "cmux-ssh-\(userID)-resolved-auth-\(basename).lock",
                isDirectory: false
            )
            .path
    }

    /// Returns the process-ownership gate for one exact cmux-owned socket.
    public func resolvedControlMasterOwnershipLockPath(
        controlPath: String
    ) -> String? {
        guard let basename = resolvedControlPathBasename(controlPath) else {
            return nil
        }
        return authenticationLockDirectory
            .appendingPathComponent(
                "cmux-ssh-\(userID)-owner-\(basename).lock",
                isDirectory: false
            )
            .path
    }

    /// Returns the shell commands that finish successful foreground authentication.
    ///
    /// The marker must be cleared before the advisory lock is released so a
    /// concurrent cleanup request cannot mistake a completed authentication
    /// attempt for one that is still in flight.
    ///
    /// - Returns: Shell commands that clear the marker, release the lock, and disarm cleanup traps.
    public func successfulForegroundAuthenticationCleanupShellLines() -> [String] {
        [
            "cmux_ssh_clear_auth_inflight",
            "if [ -n \"${cmux_ssh_resolved_auth_lock_fd:-}\" ]; then zsystem flock -u \"$cmux_ssh_resolved_auth_lock_fd\" || exit 255; fi",
            "zsystem flock -u \"$cmux_ssh_auth_lock_fd\" || exit 255",
            "trap - EXIT HUP INT TERM",
        ]
    }

    /// Builds a shell function that removes a stale cmux-owned control socket.
    ///
    /// The caller invokes the function only while holding the matching
    /// foreground-authentication lock, so one workspace cannot unlink the
    /// socket while another workspace is creating the shared master.
    ///
    /// - Parameters:
    ///   - sshArguments: SSH executable and options before the destination.
    ///   - destination: SSH destination or config alias.
    ///   - options: Effective OpenSSH `-o` values.
    ///   - functionName: Shell function name to declare.
    /// - Returns: The function declaration, or `nil` for user-managed paths.
    public func controlPathPreflightShellFunction(
        sshArguments: [String],
        destination: String,
        options: [String],
        functionName: String = "cmux_ssh_preflight_control_path"
    ) -> String? {
        guard cmuxOwnedControlPath(in: options) != nil,
              let socketPattern = resolvedControlPathShellPattern,
              !sshArguments.isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let sshPrefix = sshArguments.map(shellQuote).joined(separator: " ")
        let quotedDestination = shellQuote(destination)
        return [
            "\(functionName)() {",
            #"  cmux_ssh_control_path="$(command \#(sshPrefix) -G -- \#(quotedDestination) 2>/dev/null | awk 'tolower($1) == "controlpath" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }')" "#,
            "  case \"${cmux_ssh_control_path:-}\" in",
            "    \(socketPattern))",
            "      if ! command \(sshPrefix) -S \"$cmux_ssh_control_path\" -O check -- \(quotedDestination) >/dev/null 2>&1; then",
            "        rm -f -- \"$cmux_ssh_control_path\" 2>/dev/null || true",
            "      fi",
            "      ;;",
            "  esac",
            "  unset cmux_ssh_control_path",
            "}",
        ].joined(separator: "\n")
    }

    /// Whether `path` is one of the flat `/tmp` sockets older cmux builds
    /// used, as a template or expanded, for any uid and relay port.
    private func isSharedTemporaryControlPath(_ path: String) -> Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"\A(/private)?/tmp/cmux-ssh-[0-9]+-([0-9]+-)?(%C|[0-9a-f]{40})\z"#,
            options: .regularExpression
        ) != nil
    }

    private func isResolvedControlPath(_ path: String, in directory: String) -> Bool {
        let prefix = directory + "/"
        guard path.utf8.starts(with: prefix.utf8) else { return false }
        let name = path.utf8.dropFirst(prefix.utf8.count)
        return name.count == SSHControlSocketDirectory.socketNameLength && name.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    private func resolvedControlPathBasename(_ controlPath: String) -> String? {
        let path = controlPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("%"),
              cmuxOwnedControlPath(in: [
                  "ControlMaster=auto",
                  "ControlPath=\(path)",
              ]) == path else {
            return nil
        }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        guard !basename.isEmpty,
              basename.allSatisfy({
                  $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
              }) else {
            return nil
        }
        return basename
    }

    private func isDisabled(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["no", "false", "off", "0"].contains(value)
    }

    private func shellQuote(_ value: String) -> String {
        value.posixShellWord
    }
}
