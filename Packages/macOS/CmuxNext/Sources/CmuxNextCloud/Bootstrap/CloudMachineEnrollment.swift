import CmuxNextCompat
public import Foundation

/// `cmux cloud enroll-machine --target machine:<id> --name lane-vm-1`: makes a Cloud machine an ssh
/// host and an acpmux peer of this Mac (leo-workspace machines/lane-vms.md, steps 4 and 5).
///
/// - On the machine, through the exec API (the signed-in person's authenticated link): this Mac's
///   ssh public key goes into the `cmux` user's `authorized_keys` (once), sshd starts, and the
///   machine's ed25519 host key comes back, so it is pinned without a first-use guess.
/// - On this Mac: a `Host NAME` block in `~/.ssh/cmux-cloud/config`, which `~/.ssh/config`
///   includes, reaching the machine's private address through the app's WireGuard hub
///   (`cmux wg dial --hub`; ``CloudPaths/hubLink``), and its host key in
///   `~/.ssh/cmux-cloud/known_hosts`. So `ssh NAME` works while the app runs.
/// - Then `acp host enroll NAME`, the Add Machine card's own command: installs and starts the
///   machine's acpmux, copies the claude and codex profiles, and peers to it.
///
/// Every step is idempotent: a rerun replaces this machine's block and host key and keeps
/// everything else in the files.
public struct CloudMachineEnrollment: Equatable, Sendable {
    /// The ssh host name (`lane-vm-1`): letters, digits, `.`, `_` and `-`, not starting with `-`.
    public var name: String
    public var machineID: String
    /// The machine's private address, inside the hub's AllowedIPs.
    public var address: String
    /// One `ssh-ed25519 KEY` line, no options.
    public var publicKey: String

    public init(name: String, machineID: String, address: String, publicKey: String) {
        self.name = name
        self.machineID = machineID
        self.address = address
        self.publicKey = publicKey
    }

    public static func isHostName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// `ssh-ed25519 <base64>` from a public key file's text, its comment dropped; nil for
    /// anything else (another key type, options, several lines).
    public static func ed25519Key(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(separator: " ")
        guard !line.contains("\n"), (2...3).contains(fields.count), fields[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(fields[1])), blob.count == 51 else { return nil }
        return "ssh-ed25519 \(fields[1])"
    }

    /// The private address `cmux wg dial` reaches: an IPv4 address, or a bracketless IPv6 one.
    public static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Runs as the machine's user (the public exec's account, uid 1000 `cmux`): authorizes the
    /// key once, starts sshd, prints the host key.
    public var authorizeCommand: String {
        let line = shellQuoted("\(publicKey) cmux-enroll:\(name)")
        let blob = shellQuoted(String(publicKey.dropFirst("ssh-ed25519 ".count)))
        return [
            "set -eu", "umask 077", #"mkdir -p "$HOME/.ssh""#, #"f="$HOME/.ssh/authorized_keys""#, #"touch "$f""#,
            // A key already there is a whole `ssh-ed25519 <blob>` pair, not a substring of another line.
            #"if ! awk -v k=\#(blob) '{ for (i = 1; i < NF; i++) if ($i == "ssh-ed25519" && $(i + 1) == k) found = 1 } END { exit !found }' "$f"; then [ ! -s "$f" ] || [ -z "$(tail -c 1 "$f")" ] || printf '\n' >> "$f"; printf '%s\n' \#(line) >> "$f"; fi"#,
            #"chmod 600 "$HOME/.ssh/authorized_keys""#,
            "sudo -n systemctl enable --now ssh >/dev/null 2>&1 || sudo -n systemctl start ssh",
            "cat /etc/ssh/ssh_host_ed25519_key.pub",
        ].joined(separator: "; ")
    }

    /// A path ssh_config and the `ProxyCommand` shell read as just that path: absolute, and only
    /// letters, digits, spaces and `._+-/@` (no quote, `%`, `$`, backtick, backslash, `~` or control
    /// character, each of which ssh or the shell would act on).
    public static func isPlainPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._+-/@".unicodeScalars.contains($0)) }
    }

    /// The `Host` block, between markers ``upserting(_:into:)`` finds again. Every path must be
    /// ``isPlainPath(_:)`` (the caller checks): `ProxyCommand` runs through a shell, single-quoted.
    public func hostBlock(cli: String, hubLink: String, knownHosts: String, identityFile: String?) -> String {
        var lines = [
            "\(Self.begin(name)) \(machineID)",
            "Host \(name)",
            "  HostName \(address)",
            "  User cmux",
            "  ProxyCommand '\(cli)' wg dial --hub '\(hubLink)' %h %p",
            "  UserKnownHostsFile \(Self.configQuoted(knownHosts))",
            "  StrictHostKeyChecking yes",
        ]
        if let identityFile { lines.append("  IdentityFile \(Self.configQuoted(identityFile))") }
        lines.append(Self.end(name))
        return lines.joined(separator: "\n") + "\n"
    }

    /// `config` with this machine's block replaced (or appended), every other line kept.
    public func upserting(_ block: String, into config: String) -> String {
        var kept: [Substring] = [], inside = false
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(Self.begin(name) + " ") || line == Self.begin(name) { inside = true; continue }
            if inside { if line == Self.end(name) { inside = false }; continue }
            kept.append(line)
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text + block
    }

    /// `known_hosts` with this address's lines replaced by `hostKey` (`ssh-ed25519 <base64>`).
    public func pinning(_ hostKey: String, into knownHosts: String) -> String {
        let kept = knownHosts.split(separator: "\n").filter { $0.split(separator: " ").first.map(String.init) != address }
        return (kept.map(String.init) + ["\(address) \(hostKey)"]).joined(separator: "\n") + "\n"
    }

    /// `~/.ssh/config` with the include of the cmux file first (an `Include` after a `Host` or
    /// `Match` applies only inside that block); unchanged when it already comes first.
    public static func including(_ include: String, in config: String) -> String {
        let line = "Include \(include)"
        for raw in config.split(separator: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces), word = text.split(separator: " ").first?.lowercased()
            if text == line { return config }
            if word == "host" || word == "match" { break }
        }
        return "# cmux Cloud machines (cmux cloud enroll-machine)\n\(line)\n\n" + config
    }

    /// Writes this Mac's side (blocking file I/O: call it off the main thread): the `Host` block
    /// in `<home>/.ssh/cmux-cloud/config`, the pinned `hostKey` in its `known_hosts`, and the
    /// include at the top of `<home>/.ssh/config`. Answers the steps it took and the ones left: a
    /// `~/.ssh/config` that is a symlink (a dotfiles checkout) is never replaced; the person adds
    /// the include line there.
    public func installOnThisMac(hostKey: String, cli: String, hubLink: String, identityFile: String?, home: URL) throws -> (done: [String], pending: [String]) {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        let folder = ssh.appendingPathComponent("cmux-cloud", isDirectory: true)
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = folder.appendingPathComponent("config"), known = folder.appendingPathComponent("known_hosts")
        for path in [cli, hubLink, known.path, config.path] + (identityFile.map { [$0] } ?? []) where !Self.isPlainPath(path) {
            throw PathNotPlain(path: path)
        }
        let read = Self.readIfPresent
        try Self.write(pinning(hostKey, into: try read(known)), to: known)
        try Self.write(upserting(hostBlock(cli: cli, hubLink: hubLink, knownHosts: known.path, identityFile: identityFile), into: try read(config)), to: config)
        var done = ["ssh-config", "known-hosts"], pending: [String] = []
        let main = ssh.appendingPathComponent("config"), before = try read(main)
        let after = Self.including(config.path, in: before)
        if after != before {
            let isLink = { (try? FileManager.checked.destinationOfSymbolicLink(atPath: main.path)) != nil }
            if isLink() {
                pending.append("ssh-config-include: add `Include \(config.path)` at the top of \(main.path)")
            } else {
                // Changed or made a symlink since the read (a dotfiles tool, an editor): never written over.
                try Self.write(after, to: main, unless: { try !isLink() && read(main) == before })
                done.append("ssh-config-include")
            }
        }
        return (done, pending)
    }

    /// The file's text; "" when it does not exist. A file that exists but cannot be read as UTF-8
    /// throws, so it is never replaced by a rewrite of nothing.
    static func readIfPresent(_ url: URL) throws -> String {
        guard FileManager.checked.fileExists(atPath: url.path) else { return "" }
        return try String(blockingContentsOf: url, encoding: .utf8)
    }

    /// A path ssh_config or the `ProxyCommand` shell would read as more than a path.
    public struct PathNotPlain: Error, Equatable { public var path: String }

    /// The person's ssh config changed while enroll-machine was writing it.
    public struct ConfigChanged: Error, Equatable { public var path: String }

    /// Owner-only, through a temporary file renamed over the old one; `unchanged` is asked right
    /// before the rename.
    static func write(_ text: String, to url: URL, unless unchanged: () throws -> Bool = { true }) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).cmux-\(UUID().uuidString.prefix(8))")
        guard FileManager.checked.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard try unchanged() else {
            try? FileManager.checked.removeItem(at: temporary)
            throw ConfigChanged(path: url.path)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.checked.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func begin(_ name: String) -> String { "# >>> cmux machine \(name)" }
    static func end(_ name: String) -> String { "# <<< cmux machine \(name)" }

    /// A plain path in ssh_config: quoted when it has a space (the app bundle's `cmux NEXT.app`).
    static func configQuoted(_ text: String) -> String { text.contains(" ") ? "\"\(text)\"" : text }

    func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
