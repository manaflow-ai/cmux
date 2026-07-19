internal import Darwin
internal import Foundation

/// Merges cmux's native-SSH connection-sharing defaults without replacing
/// caller-provided OpenSSH control options.
///
/// The default `ControlPath` is stable for the local user and relies on
/// OpenSSH's `%C` expansion to separate effective `(user, host, port)`
/// endpoints. Workspace relay ports deliberately do not participate in the
/// path: reverse forwards are individual channels on the shared master.
public struct SSHConnectionSharingOptions: Sendable {
    /// Local uid used to namespace cmux-owned control sockets in `/tmp`.
    public let userID: Int
    private let authenticationLockDirectory: URL

    /// Creates an option merger for the current local user.
    public init() {
        self.userID = Int(getuid())
        self.authenticationLockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Creates an option merger for a specific local uid.
    ///
    /// - Parameter userID: Local uid used in the cmux-owned socket template.
    public init(userID: Int) {
        self.userID = userID
        self.authenticationLockDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Creates an option merger with an injected authentication-lock directory.
    ///
    /// - Parameters:
    ///   - userID: Local uid used in the cmux-owned socket template.
    ///   - authenticationLockDirectoryPath: User-private directory for authentication locks.
    public init(userID: Int, authenticationLockDirectoryPath: String) {
        self.userID = userID
        self.authenticationLockDirectory = URL(
            fileURLWithPath: authenticationLockDirectoryPath,
            isDirectory: true
        )
    }

    /// The cmux-owned, host-stable OpenSSH control-socket template.
    public var defaultControlPath: String {
        "/tmp/cmux-ssh-\(userID)-%C"
    }

    /// Adds missing sharing defaults while preserving every supplied value.
    ///
    /// A caller that disables `ControlMaster` keeps a standalone connection;
    /// cmux does not add `ControlPersist` or `ControlPath` in that case. A
    /// custom `ControlPath` or `ControlPersist` remains authoritative.
    ///
    /// - Parameter options: OpenSSH `-o` values in caller precedence order.
    /// - Returns: Trimmed options plus only the missing cmux defaults.
    public func mergingDefaults(into options: [String]) -> [String] {
        mergingDefaults(into: options, userConfiguredControlOptions: nil)
    }

    /// Adds sharing defaults while honoring effective control settings from
    /// the user's SSH configuration.
    ///
    /// Explicit caller options retain highest precedence. When the caller did
    /// not provide any control option and `ssh -G` reported non-default
    /// control settings, those effective values are carried forward instead
    /// of installing cmux's socket.
    ///
    /// - Parameters:
    ///   - options: Explicit OpenSSH `-o` values.
    ///   - userConfiguredControlOptions: Effective custom values parsed by
    ///     ``userConfiguredControlOptions(fromSSHConfigOutput:)``.
    /// - Returns: Effective explicit options for native SSH commands.
    public func mergingDefaults(
        into options: [String],
        userConfiguredControlOptions: [String]?
    ) -> [String] {
        let resolver = SSHAgentSocketResolver()
        var merged = options.compactMap { option -> String? in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
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
        let controlMaster = resolver.optionValue(named: "ControlMaster", in: merged)
        let controlMasterDisabled = isDisabled(controlMaster)
        if !controlMasterDisabled,
           let controlPath = resolver.optionValue(named: "ControlPath", in: merged),
           isLegacyRelayScopedControlPath(controlPath) {
            merged = merged.map { option in
                guard resolver.optionKey(option) == "controlpath" else { return option }
                return "ControlPath=\(defaultControlPath)"
            }
        }
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
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard ["controlmaster", "controlpath", "controlpersist"].contains(key) else {
                continue
            }
            values[key] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Keep the fallback explicitly disabled if an OpenSSH version omits default-valued keys.
        let controlMaster = values["controlmaster"] ?? "false"
        let controlPath = values["controlpath"] ?? "none"
        let controlPersist = values["controlpersist"] ?? "no"
        let hasCustomValue = !isDisabled(controlMaster)
            || controlPath.lowercased() != "none"
            || !["no", "false", "off", "0"].contains(controlPersist.lowercased())
        guard hasCustomValue else { return nil }
        return [
            "ControlMaster=\(controlMaster)",
            "ControlPath=\(controlPath)",
            "ControlPersist=\(controlPersist)",
        ]
    }

    /// Returns the configured `ControlPath` when it is one of cmux's native
    /// SSH templates, including the older relay-port-scoped template so an
    /// upgraded app can still clean up a socket it created.
    ///
    /// - Parameter options: OpenSSH `-o` values to inspect.
    /// - Returns: The cmux-owned path, or `nil` for user-managed paths.
    public func cmuxOwnedControlPath(in options: [String]) -> String? {
        let resolver = SSHAgentSocketResolver()
        guard !isDisabled(resolver.optionValue(named: "ControlMaster", in: options)) else {
            return nil
        }
        guard let rawPath = resolver.optionValue(named: "ControlPath", in: options) else {
            return nil
        }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path == defaultControlPath ||
                isStableResolvedControlPath(path) ||
                isLegacyRelayScopedControlPath(path) else {
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
              !sshArguments.isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let sshPrefix = sshArguments.map(shellQuote).joined(separator: " ")
        let quotedDestination = shellQuote(destination)
        return [
            "\(functionName)() {",
            #"  cmux_ssh_control_path="$(command \#(sshPrefix) -G \#(quotedDestination) 2>/dev/null | awk 'tolower($1) == "controlpath" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }')" "#,
            "  case \"${cmux_ssh_control_path:-}\" in",
            "    /tmp/cmux-ssh-\(userID)-*)",
            "      if ! command \(sshPrefix) -S \"$cmux_ssh_control_path\" -O check \(quotedDestination) >/dev/null 2>&1; then",
            "        rm -f -- \"$cmux_ssh_control_path\" 2>/dev/null || true",
            "      fi",
            "      ;;",
            "  esac",
            "  unset cmux_ssh_control_path",
            "}",
        ].joined(separator: "\n")
    }

    private func isLegacyRelayScopedControlPath(_ path: String) -> Bool {
        let prefix = "/tmp/cmux-ssh-\(userID)-"
        guard path.hasPrefix(prefix) else { return false }
        let remainder = path.dropFirst(prefix.count)
        if remainder.hasSuffix("-%C") {
            let relayPort = remainder.dropLast(3)
            return !relayPort.isEmpty && relayPort.allSatisfy(\.isNumber)
        }
        guard let separator = remainder.firstIndex(of: "-") else { return false }
        let relayPort = remainder[..<separator]
        let hash = remainder[remainder.index(after: separator)...]
        return !relayPort.isEmpty && relayPort.allSatisfy(\.isNumber)
            && hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    private func isStableResolvedControlPath(_ path: String) -> Bool {
        let prefix = "/tmp/cmux-ssh-\(userID)-"
        guard path.hasPrefix(prefix) else { return false }
        let hash = path.dropFirst(prefix.count)
        return hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    private func isDisabled(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["no", "false", "off"].contains(value)
    }

    private func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
