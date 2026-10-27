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

    /// `ssh-ed25519 <base64>` from a public key file's text, its comment (any number of words)
    /// dropped; nil for anything else (another key type, options, several lines).
    public static func ed25519Key(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !line.contains(where: \.isNewline), fields.count >= 2, fields[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(fields[1])), blob.count == 51 else { return nil }
        return "ssh-ed25519 \(fields[1])"
    }

    /// The private address `cmux wg dial` reaches: an IPv4 address, or a bracketless IPv6 one.
    public static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Authorizes the key once for the image's work user `cmux` (the ssh `User`), starts sshd and
    /// prints the host key. The exec may run as root or as that user, so the key file is edited
    /// as `cmux` either way (`as_u`), and root work goes through `root` (sudo when not root).
    public var authorizeCommand: String {
        [
            "set -eu", "u=cmux",
            #"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#,
            #"as_u() { if [ "$(id -un)" = "$u" ]; then "$@"; else root runuser -u "$u" -- "$@"; fi; }"#,
            #"as_u env HOME="$(getent passwd "$u" | cut -d: -f6)" sh -c \#(shellQuoted(keyEdit))"#,
            "root systemctl enable --now ssh >/dev/null 2>&1 || root systemctl start ssh",
            "cat /etc/ssh/ssh_host_ed25519_key.pub",
        ].joined(separator: "; ")
    }

    /// What runs as `cmux` in ``authorizeCommand``: `set -eu`, so a key file it cannot append to
    /// fails the enrollment. A key already there is a whole `ssh-ed25519 <blob>` pair, not a
    /// substring of another line; a file without a final newline gets one before the new key.
    public var keyEdit: String {
        let line = shellQuoted("\(publicKey) cmux-enroll:\(name)")
        let blob = shellQuoted(String(publicKey.dropFirst("ssh-ed25519 ".count)))
        return #"set -eu; umask 077; mkdir -p "$HOME/.ssh"; f="$HOME/.ssh/authorized_keys"; touch "$f"; if ! awk -v k=\#(blob) '$1 !~ /^#/ && (($1 == "ssh-ed25519" && $2 == k) || ($2 == "ssh-ed25519" && $3 == k)) { found = 1 } END { exit !found }' "$f"; then [ ! -s "$f" ] || [ -z "$(tail -c 1 "$f")" ] || printf '\n' >> "$f"; printf '%s\n' \#(line) >> "$f"; fi; chmod 600 "$f""#
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
            "  Port 22",
            "  HostKeyAlias \(hostKeyAlias)",
            "  ProxyCommand '\(cli)' wg dial --hub '\(hubLink)' %h %p",
            "  UserKnownHostsFile \(Self.configQuoted(knownHosts))",
            "  StrictHostKeyChecking yes",
            // The pinned key is the only one: no system-wide known_hosts or command can vouch for another.
            "  GlobalKnownHostsFile none",
            "  KnownHostsCommand none",
            // Every connection is its own: no master of an earlier enrollment of this name answers.
            "  ControlMaster no",
            "  ControlPath none",
        ]
        if let identityFile { lines += ["  IdentityFile \(Self.configQuoted(identityFile))", "  IdentitiesOnly yes"] }
        lines.append(Self.end(name))
        return lines.joined(separator: "\n") + "\n"
    }

    /// The cmux file's markers for this machine do not pair up (a hand edit): nothing is guessed.
    public struct MarkersDamaged: Error, Equatable { public var path: String }

    /// `config` with this machine's block replaced (or appended), every other line kept. Throws
    /// ``MarkersDamaged`` when a begin marker has no end marker after it, or an end has no begin.
    public func upserting(_ block: String, into config: String) throws -> String {
        var kept: [Substring] = [], inside = false
        for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let begins = line.hasPrefix(Self.begin(name) + " ") || line == Self.begin(name), ends = line == Self.end(name)
            if begins || ends {
                guard begins != inside else { throw MarkersDamaged(path: "") }
                inside = begins
                continue
            }
            if !inside { kept.append(line) }
        }
        guard !inside else { throw MarkersDamaged(path: "") }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        return text + block
    }

    /// The name ssh checks this machine's host key under: its own id, so no other `Host` entry's
    /// alias or address can stand in for it.
    public var hostKeyAlias: String { "cmux-\(machineID)" }

    /// `known_hosts` with this machine's lines replaced by `hostKey` (`ssh-ed25519 <base64>`),
    /// under ``hostKeyAlias``.
    public func pinning(_ hostKey: String, into knownHosts: String) -> String {
        let kept = knownHosts.split(separator: "\n").filter { $0.split(separator: " ").first.map(String.init) != hostKeyAlias }
        return (kept.map(String.init) + ["\(hostKeyAlias) \(hostKey)"]).joined(separator: "\n") + "\n"
    }

    /// A new `~/.ssh/config` holding only the include of cmux's file.
    public static func newConfig(including include: String) -> String {
        "# cmux Cloud machines (cmux cloud enroll-machine)\nInclude \(configQuoted(include))\n"
    }

    /// Writes this Mac's side (blocking file I/O: call it off the main thread): the `Host` block
    /// in `<home>/.ssh/cmux-cloud/config`, the pinned `hostKey` in its `known_hosts`, and a new
    /// `<home>/.ssh/config` with the include when there is none. An existing `~/.ssh/config` is
    /// never written; whether it reaches the route, `ssh -G` says (``routeIsLive(_:)``).
    public func installOnThisMac(hostKey: String, cli: String, hubLink: String, identityFile: String?, home: URL) throws -> (done: [String], pending: [String]) {
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        let folder = ssh.appendingPathComponent("cmux-cloud", isDirectory: true)
        // Ours alone: never through a symlink to somewhere else. The folder is opened with
        // O_NOFOLLOW and locked through that descriptor; after the writes it must still be the same
        // directory (device and inode), or the run fails without having trusted a swapped path.
        try FileManager.checked.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let lock = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw PathNotPlain(path: folder.path) }
        defer { close(lock) }
        // One enrollment at a time edits these files (two at once would lose one's block or key).
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: folder.path]) }
        var held = stat()
        guard fstat(lock, &held) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let sameFolder = { () -> Bool in
            var now = stat()
            return lstat(folder.path, &now) == 0 && now.st_dev == held.st_dev && now.st_ino == held.st_ino
        }
        guard sameFolder() else { throw PathNotPlain(path: folder.path) }
        let config = folder.appendingPathComponent("config"), known = folder.appendingPathComponent("known_hosts")
        for path in [cli, hubLink, known.path, config.path] + (identityFile.map { [$0] } ?? []) where !Self.isPlainPath(path) {
            throw PathNotPlain(path: path)
        }
        let read = Self.readIfPresent
        try Self.write(pinning(hostKey, into: try read(known)), to: known)
        let block = hostBlock(cli: cli, hubLink: hubLink, knownHosts: known.path, identityFile: identityFile)
        do { try Self.write(try upserting(block, into: try read(config)), to: config) } catch is MarkersDamaged { throw MarkersDamaged(path: config.path) }
        guard sameFolder() else { throw PathNotPlain(path: folder.path) }
        var done = ["ssh-config", "known-hosts"]
        if try Self.createIncluding(config.path, at: ssh.appendingPathComponent("config")) { done.append("ssh-config-include") }
        return (done, [])
    }

    /// Creates the person's `~/.ssh/config` holding only the include, when there is none (an
    /// existing file or symlink is never opened, so nothing of the person's is ever rewritten). False when one exists: then `ssh -G` decides
    /// (``routeIsLive(_:)``), and the person adds the include if it is missing.
    static func createIncluding(_ include: String, at main: URL) throws -> Bool {
        var existing = stat()
        if lstat(main.path, &existing) == 0 { return false }
        // Whole or not at all: a temporary file, then link(2), which fails if one appeared meanwhile.
        let temporary = main.deletingLastPathComponent().appendingPathComponent(".config.cmux-\(UUID().uuidString.prefix(8))")
        guard FileManager.checked.createFile(atPath: temporary.path, contents: Data(newConfig(including: include).utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: main.path])
        }
        defer { unlink(temporary.path) }
        if link(temporary.path, main.path) == 0 { return true }
        if errno == EEXIST { return false }
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    /// Whether `ssh -G NAME`'s answer (OpenSSH's own reading of every config and include) is
    /// exactly this machine's route: its address, this app's `wg dial` through this hub link and
    /// cmux's pinned known_hosts. Anything else (no include, an earlier `Host NAME` elsewhere, a
    /// conditional include, another proxy or known_hosts) is not.
    public func routeIsLive(_ sshG: String, cli: String, hubLink: String, knownHosts: String) -> Bool {
        var seen: [String: String] = [:]
        for line in sshG.split(whereSeparator: \.isNewline) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space]), value = String(line[line.index(after: space)...])
            if seen[key] == nil { seen[key] = value }
        }
        return seen["hostname"] == address && seen["user"] == "cmux" && seen["port"] == "22" && seen["hostkeyalias"] == hostKeyAlias
            && seen["proxycommand"] == "'\(cli)' wg dial --hub '\(hubLink)' %h %p"
            && seen["userknownhostsfile"] == knownHosts
            && seen["stricthostkeychecking"] == "true"
            && seen["globalknownhostsfile"] == "none" && (seen["knownhostscommand"] ?? "none") == "none"
            && seen["controlmaster"] == "false" && (seen["controlpath"] ?? "none") == "none"
    }

    /// The file's text; "" when it does not exist. A file that exists but cannot be read as UTF-8
    /// throws, so it is never replaced by a rewrite of nothing.
    static func readIfPresent(_ url: URL) throws -> String {
        guard FileManager.checked.fileExists(atPath: url.path) else { return "" }
        return try String(blockingContentsOf: url, encoding: .utf8)
    }

    /// A path ssh_config or the `ProxyCommand` shell would read as more than a path.
    public struct PathNotPlain: Error, Equatable { public var path: String }

    /// A file of cmux's own folder, owner-only, through a temporary file renamed over the old one.
    static func write(_ text: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).cmux-\(UUID().uuidString.prefix(8))")
        guard FileManager.checked.createFile(atPath: temporary.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.checked.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    static func begin(_ name: String) -> String { "# >>> cmux machine \(name)" }
    static func end(_ name: String) -> String { "# <<< cmux machine \(name)" }

    /// A plain path in ssh_config: quoted when it has a space (the app bundle's `cmux NEXT.app`).
    public static func configQuoted(_ text: String) -> String { text.contains(" ") ? "\"\(text)\"" : text }

    func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
