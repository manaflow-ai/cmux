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
        let positionals = rest.filter { !$0.hasPrefix("-") }
        // The verb itself (list/ls) is expected; anything else is a user error.
        for extra in positionals where extra.lowercased() != "list" && extra.lowercased() != "ls" {
            throw CLIError(message: """
                ssh list: unexpected argument '\(extra)'.

                \(Self.sshListUsage)
                """)
        }

        let configPath = Self.resolveSSHConfigPath(configOverride)
        let hosts = Self.loadSSHConfigHosts(configPath: configPath)

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
    /// directives against the real filesystem. A missing file is treated as
    /// "no hosts" rather than an error (a fresh machine has no ssh_config).
    static func loadSSHConfigHosts(configPath: String) -> [SSHConfigHost] {
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }
        // OpenSSH resolves every relative `Include` under a single fixed base
        // (`~/.ssh` for a user config), independent of nesting depth — the
        // including file's own directory does not matter (ssh_config(5):
        // "Files without absolute paths are assumed to be in ~/.ssh"). So the
        // base is captured once here and shared by every (possibly nested)
        // include, rather than re-derived per included file. For the default
        // `~/.ssh/config` this base is exactly `~/.ssh`.
        let baseDirectory = (configPath as NSString).deletingLastPathComponent
        let resolver: (String) -> [String] = { argument in
            Self.sshIncludeFileContents(argument: argument, baseDirectory: baseDirectory)
        }
        return SSHConfigParser().hosts(configText: contents, includeResolver: resolver)
    }

    /// Expand an `Include` directive argument into the contents of each matched
    /// file. Mirrors OpenSSH: whitespace separates multiple patterns, `~`
    /// expands to home, and a relative path resolves against `baseDirectory`
    /// (the directory of the config file being listed — `~/.ssh` for the
    /// default config), which is the same fixed base at every nesting depth per
    /// ssh_config(5). `*`/`?` globs in the final path component are expanded and
    /// matches are read in lexical order.
    private static func sshIncludeFileContents(argument: String, baseDirectory: String) -> [String] {
        var results: [String] = []
        let patterns = argument.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for pattern in patterns {
            let expanded: String
            if pattern.hasPrefix("~") {
                expanded = (pattern as NSString).expandingTildeInPath
            } else if pattern.hasPrefix("/") {
                expanded = pattern
            } else {
                expanded = (baseDirectory as NSString).appendingPathComponent(pattern)
            }
            for path in Self.expandIncludeGlob(expanded) {
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    results.append(text)
                }
            }
        }
        return results
    }

    /// Expand a single include path that may contain a `*`/`?` glob in its last
    /// component. Returns matching regular-file paths in lexical order.
    private static func expandIncludeGlob(_ path: String) -> [String] {
        let ns = path as NSString
        let last = ns.lastPathComponent
        let fileManager = FileManager.default
        guard last.contains("*") || last.contains("?") else {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return (exists && !isDirectory.boolValue) ? [path] : []
        }
        let directory = ns.deletingLastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return entries
            // FNM_PERIOD mirrors glob(3) (what OpenSSH uses to expand Include):
            // an unqualified `*` must not match dotfiles like `.vault-config`,
            // so cmux reads exactly the files ssh would.
            .filter { fnmatch(last, $0, FNM_PERIOD) == 0 }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
            .filter { candidate in
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory)
                return exists && !isDirectory.boolValue
            }
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
