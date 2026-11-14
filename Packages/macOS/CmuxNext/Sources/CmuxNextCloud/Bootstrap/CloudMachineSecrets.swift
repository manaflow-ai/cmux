import CmuxNextCompat
import Darwin
public import Foundation

/// `cmux cloud deliver-secrets --target machine:<id>`: the values of the secret names a machine's
/// `.cmux/machine.toml` declares, from this Mac's Keychain (`cmux cloud secret set`, service
/// ``service``) to `~/.config/cmux/machine-secrets.env` (0600) on the machine, which its
/// `machine.env` sources.
///
/// To a Cloud machine each value is sealed on this Mac with HPKE to the machine's daemon key and sent
/// over its carrier (`cmux carrier secrets`, cmux-tui `carrier/secrets.rs`); only that daemon opens it
/// (`secrets-v1`, cmux-remote `secrets/`). Own SSH machines and acpmux peers have no carrier: they keep
/// the terminal receiver (CloudMachineSecrets+SSHReceiver.swift).
/// A machine whose ledger entry (``Ledger``) matches what the Mac holds is not delivered to again.
///
/// The machine says which names it wants (its status); the Mac decides the scope: repo-scoped
/// values only for the `--repo` the person names, else the global ones. A machine can ask for any
/// global name, which is what global means.
public struct CloudMachineSecrets: Equatable, Sendable {
    public init() {}
    public static let service = "cmux-cloud-secret"

    /// One declared name and the Keychain account that holds its value (`owner/name/NAME`, else `*/NAME`).
    public struct Item: Equatable, Sendable {
        public var name: String
        public var account: String
        /// When `cmux cloud secret set` stored it, unix ms (the ledger's change mark).
        public var setAtMs: Int64
    }

    /// The names a machine declares, the repo scope the person named (`owner/name`, lowercased),
    /// and what the Mac's index (`~/.config/cmux/cloud-secrets.json`) lists. Names with no value here
    /// are `missing`; a name the machine repeats or that is not a plain name is dropped.
    public static func plan(declared: [String], repo: String?, index: [String: Int64]) -> (items: [Item], missing: [String]) {
        var items: [Item] = [], missing: [String] = [], seen = Set<String>()
        for name in declared where isName(name) && seen.insert(name).inserted {
            let accounts = (repo.map { ["\($0.lowercased())/\(name)"] } ?? []) + ["*/\(name)"]
            if let account = accounts.first(where: { index[$0] != nil }), let at = index[account] {
                items.append(Item(name: name, account: account, setAtMs: at))
            } else {
                missing.append(name)
            }
        }
        return (items, missing)
    }

    /// The secret names the machine's last finished apply declared (``CloudMachineConfig/statusPath``);
    /// nil while none has finished, or for a status that does not say (never read as "no secrets").
    public static func declared(status data: Data?) -> [String]? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["state"] as? String, state == "done" || state == "failed",
              let secrets = root["secrets"] as? [String: Any], let names = secrets["declared"] as? [String] else { return nil }
        return names
    }

    /// `OWNER/NAME` as `cmux cloud secret set --repo` scopes it (lowercased); nil when it is not one.
    public static func repoScope(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let plain = { (part: Substring) in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
        }
        return parts.count == 2 && parts.allSatisfy(plain) ? text.lowercased() : nil
    }

    /// The repo the machine says it was set up from (`~/.cmux/bootstrap/repo.json`, `owner/name`
    /// lowercased): never a scope by itself (the machine wrote it), only a reason to ask for `--repo`.
    public static func claimedRepo(record data: Data?) -> String? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = root["owner"] as? String, let name = root["name"] as? String else { return nil }
        return repoScope("\(owner)/\(name)")
    }

    /// Whether the index holds a value scoped to `repo` for any of `declared`: delivering without `--repo`
    /// would then quietly send the global value instead.
    public static func hasRepoValues(for declared: [String], repo: String, index: [String: Int64]) -> Bool {
        declared.contains { index["\(repo)/\($0)"] != nil }
    }

    /// A value `cmux cloud secret set` would take: at least 8 characters (Unicode scalars: the applier
    /// masks every value wherever setup prints it, so a shorter one would mask ordinary output), at most
    /// 16 KiB, one line, no NUL. Scalars, not Characters: "\r\n" is one Character.
    public static func isValue(_ value: String) -> Bool {
        value.unicodeScalars.count >= 8 && value.utf8.count <= 16 * 1024
            && !value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }

    /// `<scope>/<NAME>` as `cmux cloud secret set` writes it: scope `*` or a lowercased `owner/name`.
    static func isAccount(_ account: String) -> Bool {
        guard let slash = account.lastIndex(of: "/") else { return false }
        let scope = String(account[..<slash]), name = String(account[account.index(after: slash)...])
        return isName(name) && (scope == "*" || repoScope(scope) == scope)
    }

    /// The machine config's name rule (`[A-Za-z_][A-Za-z0-9_]*`, at most 128), and not a name the
    /// machine's shell, libc, python or cmux owns: the same list as the applier (``CloudMachineConfig``)
    /// and `cmux cloud secret set`, so a value under such a name is never delivered, whatever made it.
    public static func isName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128 else { return false }
        let letter = { (c: Unicode.Scalar) in c.isASCII && (CharacterSet.letters.contains(c) || c == "_") }
        guard letter(first), name.unicodeScalars.allSatisfy({ letter($0) || ("0"..."9").contains($0) }) else { return false }
        let upper = name.uppercased()
        return !reservedNames.contains(upper) && !reservedPrefixes.contains { upper.hasPrefix($0) }
    }

    static let reservedNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PWD", "OLDPWD", "TERM",
        "BASH", "BASHOPTS", "BASHPID", "CDPATH", "COLUMNS", "DIRSTACK", "EPOCHREALTIME", "EPOCHSECONDS", "EUID", "EXECIGNORE",
        "FCEDIT", "FIGNORE", "FUNCNAME", "FUNCNEST", "GLOBIGNORE", "GROUPS", "HOSTFILE", "HOSTNAME", "HOSTTYPE", "IGNOREEOF",
        "INPUTRC", "LINENO", "LINES", "MACHTYPE", "MAIL", "MAILCHECK", "MAILPATH", "OPTARG", "OPTERR", "OPTIND", "OSTYPE",
        "PIPESTATUS", "POSIXLY_CORRECT", "PPID", "RANDOM", "REPLY", "SECONDS", "SHELLOPTS", "SHLVL", "SRANDOM", "TIMEFORMAT",
        "TMOUT", "TMPDIR", "UID", "_", "PS0", "PS1", "PS2", "PS3", "PS4", "HISTCMD", "HISTCONTROL", "HISTFILE", "HISTFILESIZE",
        "HISTIGNORE", "HISTSIZE", "HISTTIMEFORMAT", "LANG", "LANGUAGE", "TZ", "TZDIR", "NLSPATH",
        "ZDOTDIR", "FPATH", "MODULE_PATH", "PROMPT", "PROMPT2", "PROMPT3", "PROMPT4", "RPROMPT", "RPROMPT2", "RPS1",
        "RPS2", "NULLCMD", "READNULLCMD", "HISTCHARS", "WATCHFMT", "PERIOD", "KEYTIMEOUT", "SAVEHIST", "STTY",
        "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONUSERBASE", "PYTHONSAFEPATH",
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
    ]
    static let reservedPrefixes = ["LD_", "DYLD_", "CMUX_", "BASH_", "COMP_", "PROMPT_", "READLINE_", "COPROC", "LC_", "ZSH_"]

    /// A file of this Mac's (the index, the ledger), read by ``read(_:max:)``.
    public enum LocalFile: Equatable, Sendable {
        /// Not there (`ENOENT`): nothing was ever written.
        case missing
        case bytes(Data)
        /// There, or maybe there (a folder that cannot be searched), but not a regular file of at most
        /// `max` bytes that could be read: never taken for `missing`.
        case unreadable
    }

    /// The file at `path`, opened without following a link or waiting on a FIFO, read only when it is a
    /// regular file, never past `max` bytes. Blocking file I/O.
    public static func read(_ path: String, max: Int = 1 << 20) -> LocalFile {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(max) else { return .unreadable }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= max {
            let count = buffer.withUnsafeMutableBytes { blockingRead(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { return count == 0 ? .bytes(data) : .unreadable }
            data.append(contentsOf: buffer[..<count])
        }
        return .unreadable  // grew past `max` while it was read
    }

    /// The index file's `secrets` object (empty when there is no file: nothing was ever set); nil for a
    /// file that is there (or may be) but cannot be read as one, never taken for "no secrets".
    public static func index(from file: LocalFile) -> [String: Int64]? {
        let data: Data
        switch file {
        case .missing: return [:]
        case .unreadable: return nil
        case .bytes(let bytes): data = bytes
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secrets = root["secrets"] as? [String: Any] else { return nil }
        var index: [String: Int64] = [:]
        for (account, at) in secrets {
            // A non-negative JSON integer (never a boolean or a fraction) for a well-formed account.
            guard isAccount(account), let at = at as? NSNumber, CFGetTypeID(at) != CFBooleanGetTypeID(),
                  "qlisQLIS".contains(String(cString: at.objCType)), at.int64Value >= 0 else { return nil }
            index[account] = at.int64Value
        }
        return index
    }

    /// What was delivered to which machine: `machine -> account -> setAtMs`. No value, ever.
    public struct Ledger: Equatable, Sendable, Codable {
        public var machines: [String: [String: Int64]] = [:]

        public init(machines: [String: [String: Int64]] = [:]) {
            self.machines = machines
        }

        /// The ledger in `file`; empty for one that is missing or cannot be read (the next delivery to
        /// each machine then happens again, which is safe).
        public init(file: LocalFile) {
            guard case .bytes(let data) = file, let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
                self.init()
                return
            }
            self = ledger
        }

        /// Whether `items` are exactly what `machine` already has.
        /// Also false for a machine with no record: an empty set is delivered once, so a machine that
        /// had values (and a ledger that lost its record) gets its file cleared.
        public func isCurrent(_ items: [Item], on machine: String) -> Bool {
            machines[machine] == Dictionary(uniqueKeysWithValues: items.map { ($0.account, $0.setAtMs) })
        }

        /// Records `items` for `machine` in the ledger file at `url`, under an flock on `<url>.lock`, by
        /// a read-modify-write, so two deliveries to different machines keep both. Blocking file I/O.
        public static func record(_ items: [Item], on machine: String, at url: URL) throws {
            let lock = open(url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var ledger = Ledger(file: CloudMachineSecrets.read(url.path))
            ledger.record(items, on: machine)
            try JSONEncoder().encode(ledger).blockingWrite(to: url, options: [.atomic])
        }

        public mutating func record(_ items: [Item], on machine: String) {
            machines[machine] = Dictionary(uniqueKeysWithValues: items.map { ($0.account, $0.setAtMs) })
        }
    }
}
