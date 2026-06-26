import CmuxFoundation
import Darwin
import Foundation

// `cmux ssh list` (alias `ls`): list the SSH hosts defined in the user's
// ssh_config — the "external" machines cmux can connect to with
// `cmux ssh <alias>` (https://github.com/manaflow-ai/cmux/issues/6774).
//
// This is a local, no-socket command: it only reads `~/.ssh/config` (following
// its `Include` directives) and never talks to the running app, so it works
// even when cmux is not running. Parsing lives in `SSHConfigParser`
// (CmuxFoundation) so it is unit-tested independently of this presentation
// layer; this file owns only the filesystem glue and the printed output.
extension CMUXCLI {
    static let sshListUsage = """
        Usage: cmux ssh list [--config <path>] [--json]

        List the SSH hosts defined in your ssh_config — the "external" machines
        cmux can connect to with `cmux ssh <alias>`. Reads ~/.ssh/config by
        default, follows its `Include` directives, and shows each host's
        resolved HostName/User/Port plus any forwarded ports it declares
        (LocalForward / RemoteForward / DynamicForward).

          --config <path>   Read this config file instead of ~/.ssh/config
          --json            Emit machine-readable JSON

        `list` (and its alias `ls`) is reserved here; to open an alias literally
        named "list", connect with its full destination, e.g. `cmux ssh user@list`.
        """

    /// Whether `cmux ssh ...` is the local `list`/`ls` subcommand (handled
    /// without a socket because it only reads the local ssh_config) rather than
    /// a connect request.
    ///
    /// The verb must be the *first* token. Scanning for the first non-dash
    /// token instead would misread an option value: `cmux ssh --name list
    /// dev@host` (or `--ssh-option list …`) would treat the `--name` value
    /// `list` as the subcommand and hijack a real connect. Like `vm ls` /
    /// `remotes list`, `list`/`ls` are reserved only in leading position.
    func sshCommandIsListing(_ commandArgs: [String]) -> Bool {
        guard let first = commandArgs.first else { return false }
        let verb = first.lowercased()
        return verb == "list" || verb == "ls"
    }

    func runSSHListCommand(commandArgs: [String], jsonOutput: Bool) throws {
        // `--help`/`-h` are handled upstream by the help pre-dispatch in
        // `cmux.swift` (which prints the `cmux ssh list` header + usage) before
        // this runs, and the verb is always `list`/`ls`, so no help branch is
        // needed here.
        let (configOverride, rest) = parseOption(commandArgs, name: "--config")
        // `parseOption` leaves a value-less `--config` (when it is the final
        // token) in `rest`, and `--config=` / `--config ""` yield an empty
        // value. Either way the user named the flag but no file, so fail loudly
        // instead of silently reading the default config.
        if rest.contains("--config") || configOverride?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            throw CLIError(message: """
                ssh list: --config requires a path.

                \(Self.sshListUsage)
                """)
        }
        // The only expected token is the `list`/`ls` verb (global `--json` was
        // consumed before this). Anything else — an unknown or misspelled flag
        // like `--bogus`/`--jsno`, or an extra positional — is a user error,
        // not a silently-ignored argument.
        for token in rest where token.lowercased() != "list" && token.lowercased() != "ls" {
            throw CLIError(message: """
                ssh list: unexpected argument '\(token)'.

                \(Self.sshListUsage)
                """)
        }

        let configPath = Self.resolveSSHConfigPath(configOverride)
        let hosts = try Self.loadSSHConfigHosts(configPath: configPath, requireReadable: configOverride != nil)

        if jsonOutput {
            let payload: [String: Any] = [
                "configPath": configPath,
                "hosts": hosts.map(Self.sshHostJSON),
            ]
            print(jsonString(payload))
            return
        }

        if hosts.isEmpty {
            print("No SSH hosts found in \(configPath).")
            return
        }
        printSSHHostsTable(hosts)
    }

    /// Resolve the ssh_config path to read: an explicit `--config` override
    /// (tilde-expanded) or the default `~/.ssh/config`.
    static func resolveSSHConfigPath(_ override: String?) -> String {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    /// Read and parse the ssh_config at `configPath`, expanding `Include`
    /// directives against the real filesystem.
    ///
    /// A missing/unreadable default `~/.ssh/config` is treated as "no hosts"
    /// (a fresh machine has none). When `requireReadable` is true — an explicit
    /// `--config` override — a read failure is surfaced as an error instead, so
    /// a typo'd path or permission problem is not silently shown as an empty
    /// config.
    static func loadSSHConfigHosts(configPath: String, requireReadable: Bool) throws -> [SSHConfigHost] {
        // Guard the top-level read the same way include matches are guarded: a
        // FIFO/device/socket would block `String(contentsOfFile:)` indefinitely,
        // and this command is meant to be a fast, no-socket local read. A
        // missing/non-regular default config means no hosts; an explicit
        // --config that is missing or non-regular is a user error.
        guard Self.isRegularFile(configPath) else {
            if requireReadable {
                throw CLIError(message: "ssh list: --config \(configPath) is not a readable file.")
            }
            return []
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: configPath, encoding: .utf8)
        } catch {
            if requireReadable {
                throw CLIError(message: "ssh list: cannot read --config \(configPath): \(error.localizedDescription)")
            }
            return []
        }
        // OpenSSH resolves every relative `Include` in a user configuration
        // under `~/.ssh` — even with an explicit `-F`/`--config` path the base
        // is the user SSH directory, not the config file's own directory
        // (ssh_config(5): "Files without absolute paths are assumed to be in
        // ~/.ssh"; verified with `ssh -G -F`). So resolve relative includes
        // under ~/.ssh regardless of where the config file lives, listing
        // exactly what ssh would read. (For the default ~/.ssh/config this is
        // the same directory.)
        let userSSHDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        let resolver: (String) -> [String] = { path in
            Self.sshIncludeFile(path: path, baseDirectory: userSSHDirectory)
        }
        return SSHConfigParser().hosts(configText: contents, includeResolver: resolver)
    }

    /// Expand a single `Include` path into the contents of each file it matches.
    /// Mirrors OpenSSH: `~` expands to home, and a relative path resolves
    /// against `baseDirectory` — the user SSH directory (`~/.ssh`) for a user
    /// configuration, at every nesting depth per ssh_config(5). Glob wildcards
    /// in any path component are expanded (via `glob(3)`) and matches are read in
    /// sorted order. The parser has already tokenized multi-path / quoted
    /// `Include` arguments, so this receives exactly one path.
    private static func sshIncludeFile(path: String, baseDirectory: String) -> [String] {
        let expanded: String
        if path.hasPrefix("~") {
            expanded = (path as NSString).expandingTildeInPath
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            expanded = (baseDirectory as NSString).appendingPathComponent(path)
        }
        var results: [String] = []
        for filePath in Self.expandIncludeGlob(expanded) {
            if let text = try? String(contentsOfFile: filePath, encoding: .utf8) {
                results.append(text)
            }
        }
        return results
    }

    /// Expand a single include path with POSIX `glob(3)` — the same call
    /// OpenSSH uses for `Include`. Unlike a last-component-only matcher this
    /// honors wildcards in any path component (e.g. `hosts/*/config`), and with
    /// default flags an unqualified `*` does not match dotfiles, exactly as
    /// OpenSSH behaves. A literal (wildcard-free) path round-trips through glob
    /// too: it matches iff it exists. Only regular files are returned, in glob's
    /// sorted order.
    private static func expandIncludeGlob(_ pattern: String) -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard pattern.withCString({ glob($0, 0, nil, &globResult) }) == 0 else { return [] }
        var matches: [String] = []
        if let pathv = globResult.gl_pathv {
            for index in 0..<Int(globResult.gl_pathc) {
                guard let cString = pathv[index] else { continue }
                // Only read regular files. `glob` can match directories, FIFOs,
                // devices, or sockets; reading a FIFO would block `cmux ssh list`
                // indefinitely and a device could consume unbounded resources.
                let path = String(cString: cString)
                if Self.isRegularFile(path) { matches.append(path) }
            }
        }
        return matches
    }

    /// Whether `path` resolves (through symlinks) to a regular file — the only
    /// thing safe to read. `stat` follows symlinks, so a symlink to a regular
    /// file (what ssh would read) is kept, while a FIFO, device, socket, or
    /// directory is rejected before `String(contentsOfFile:)` can block or
    /// consume unbounded resources.
    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return false }
        return (Int32(info.st_mode) & S_IFMT) == S_IFREG
    }

    private static func sshHostJSON(_ host: SSHConfigHost) -> [String: Any] {
        var dict: [String: Any] = ["alias": host.alias]
        if let value = host.hostName { dict["hostName"] = value }
        if let value = host.user { dict["user"] = value }
        if let value = host.port { dict["port"] = value }
        if let value = host.identityFile { dict["identityFile"] = value }
        if let value = host.proxyJump { dict["proxyJump"] = value }
        if !host.localForwards.isEmpty { dict["localForwards"] = host.localForwards }
        if !host.remoteForwards.isEmpty { dict["remoteForwards"] = host.remoteForwards }
        if !host.dynamicForwards.isEmpty { dict["dynamicForwards"] = host.dynamicForwards }
        return dict
    }

    private func printSSHHostsTable(_ hosts: [SSHConfigHost]) {
        for host in hosts {
            let alias = Self.sanitizeForTerminal(host.alias)
            var target = ""
            if let hostName = host.hostName {
                let userPrefix = host.user.map { "\(Self.sanitizeForTerminal($0))@" } ?? ""
                target = "  \(userPrefix)\(Self.sanitizeForTerminal(hostName))"
                if let port = host.port { target += ":\(port)" }
            } else if let port = host.port {
                target = "  :\(port)"
            }
            var extras: [String] = []
            if let proxyJump = host.proxyJump {
                extras.append("via \(Self.sanitizeForTerminal(proxyJump))")
            }
            let forwards = host.localForwards.map { "L:\($0)" }
                + host.remoteForwards.map { "R:\($0)" }
                + host.dynamicForwards.map { "D:\($0)" }
            if !forwards.isEmpty {
                let rendered = forwards.map(Self.sanitizeForTerminal).joined(separator: ", ")
                extras.append("forwards=[\(rendered)]")
            }
            let extraText = extras.isEmpty ? "" : "  \(extras.joined(separator: "  "))"
            print("\(alias)\(target)\(extraText)")
        }
    }
}
