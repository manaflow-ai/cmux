import CmuxNextCompat
import CryptoKit
import Darwin
public import Foundation

/// `cmux cloud deliver-secrets --target machine:<id>`: the values of the secret names a machine's
/// `.cmux/machine.toml` declares, from this Mac's Keychain (`cmux cloud secret set`, service
/// ``service``) to `~/.config/cmux/machine-secrets.env` (0600) on the machine, which its
/// `machine.env` sources.
///
/// A value travels only over the machine's daemon link (the app's authenticated, encrypted
/// connection to its session daemon), typed into a short-lived terminal that runs ``receiver``
/// with echo off: never through the exec API, an argv, the Cloud file API or a log. The file API
/// carries only the receiver, which holds no secret, and its ticket (``ticket(nonce:key:names:)``:
/// a one-time nonce, a payload key and the names, no value), which the receiver reads and removes
/// before anything else, so no terminal environment, argv, screen or receipt ever holds them. The
/// receiver prints ``ready`` and the nonce once echo is off (another client typing into the
/// terminal cannot fake the go-ahead), reads base64 lines up to ``end``, writes the file and
/// answers ``ok`` or ``error`` with a fixed code.
/// A machine whose ledger entry (``Ledger``) matches what the Mac holds is not delivered to again.
///
/// The machine says which names it wants (its status); the Mac decides the scope: repo-scoped
/// values only for the `--repo` the person names, else the global ones. A machine can ask for any
/// global name, which is what global means.
public struct CloudMachineSecrets: Equatable, Sendable {
    public init() {}
    public static let service = "cmux-cloud-secret"
    public static let receiverPath = CloudMachineConfig.directory + "/receive-secrets"
    /// The receiver's ticket, in the work user's 0700 folder beside it.
    public static let ticketPath = CloudMachineConfig.directory + "/receive-secrets.ticket"
    public static let ready = "CMUX-SECRETS-READY"
    public static let end = "CMUX-SECRETS-END"
    public static let ok = "CMUX-SECRETS-OK"
    public static let error = "CMUX-SECRETS-ERR"
    /// How long the receiver waits for the whole payload before it gives up (and the Mac waits for each answer).
    public static let waitSeconds = 60

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
    /// 16 KiB (100 of them fit ``maxPayloadBytes``), one line, no NUL. Scalars, not Characters: "\r\n" is one Character.
    public static func isValue(_ value: String) -> Bool {
        value.unicodeScalars.count >= 8 && value.utf8.count <= 16 * 1024
            && !value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }

    /// The size of the file the receiver writes for `values` (`export NAME='value'`, each `'` as `'\''`):
    /// the applier reads machine-secrets.env only up to ``maxEnvFileBytes``.
    static func envFileBytes(_ values: [(name: String, value: String)]) -> Int {
        values.reduce(0) { total, item in
            total + "export ".utf8.count + item.name.utf8.count + "=''\n".utf8.count + item.value.utf8.count
                + 3 * item.value.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "'") ? 1 : 0) }
        }
    }

    /// The largest machine-secrets.env the applier reads (and so masks and sources): 4 MiB.
    public static let maxEnvFileBytes = 4 << 20

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

    /// The bytes typed into the receiver: base64 of `NAME=value` lines, 76 columns a line, then
    /// ``mac`` with the SHA-256 of `key`, a line feed and those lines, then ``end`` and `key`. `key`
    /// reaches the receiver only in its ticket and is never printed, so text another client types
    /// into the terminal (it sees the screen, never the ticket) can only make the delivery fail:
    /// the receiver keeps the old set unless both match. A value is one line (`cmux cloud secret set`
    /// refuses line breaks).
    public static func payload(_ values: [(name: String, value: String)], key: String) -> Data {
        let body = values.map { "\($0.name)=\($0.value)\n" }.joined()
        var encoded = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        if !encoded.isEmpty { encoded += "\n" }
        let digest = SHA256.hash(data: Data((key + "\n" + encoded).utf8)).map { String(format: "%02x", $0) }.joined()
        return Data((encoded + "\(mac) \(digest)\n\(end) \(key)\n").utf8)
    }

    public static let mac = "CMUX-SECRETS-MAC"

    /// The receiver's ticket: the nonce, the payload key and the names it may write (space-separated),
    /// a line each. No value.
    public static func ticket(nonce: String, key: String, names: [String]) -> Data {
        Data("\(nonce)\n\(key)\n\(names.joined(separator: " "))\n".utf8)
    }

    /// The calls a delivery makes (the ticket over the file API, the rest over the machine's daemon
    /// link), so a test records them.
    public struct Link: Sendable {
        /// Writes the receiver's ticket (``ticketPath``).
        public var writeTicket: @Sendable (_ ticket: Data) async throws -> Void
        /// Starts `argv` in a new terminal; answers its handle.
        public var start: @Sendable (_ argv: [String]) async throws -> String
        /// Waits until the terminal's screen matches `pattern` (a regex); answers the screen text.
        public var waitFor: @Sendable (_ terminal: String, _ pattern: String, _ seconds: Int) async throws -> String
        /// Types `bytes` into the terminal.
        public var type: @Sendable (_ terminal: String, _ bytes: Data) async throws -> Void
        public var close: @Sendable (_ terminal: String) async -> Void

        public init(writeTicket: @escaping @Sendable (Data) async throws -> Void,
                    start: @escaping @Sendable ([String]) async throws -> String,
                    waitFor: @escaping @Sendable (String, String, Int) async throws -> String,
                    type: @escaping @Sendable (String, Data) async throws -> Void,
                    close: @escaping @Sendable (String) async -> Void) {
            self.writeTicket = writeTicket
            self.start = start
            self.waitFor = waitFor
            self.type = type
            self.close = close
        }
    }

    public struct DeliveryFailed: Error, Equatable {
        public var reason: String

        public init(reason: String) { self.reason = reason }
    }

    /// The receiver's error codes; any other answer is reported as `unexpected`, so nothing a
    /// machine prints (possibly a value) reaches an error.
    static let errorCodes: Set<String> = ["no-tty", "mkdir", "mktemp", "too-large", "eof", "bad-base64", "bad-name", "bad-line", "duplicate", "write", "interrupted", "nonce", "bad-mac"]

    /// Runs the receiver in a new terminal, types the payload once it says echo is off, and closes
    /// the terminal. Answers how many names the machine wrote. `receiverAt` and `ticketAt` are where the
    /// link put them (an own machine's are under its own home, `SSHMachineSecrets`).
    public static func deliver(_ values: [(name: String, value: String)], over link: Link,
                               nonce: String = randomHex(), key: String = randomHex(),
                               receiverAt: String = receiverPath, ticketAt: String = ticketPath) async throws -> Int {
        let typed = payload(values, key: key)
        // The receiver's own limits: a set too large is refused here, before any terminal opens.
        guard typed.count <= maxPayloadBytes, envFileBytes(values) <= maxEnvFileBytes else { throw DeliveryFailed(reason: "too-large") }
        // The names travel with the key: the receiver writes these and nothing else.
        try await link.writeTicket(ticket(nonce: nonce, key: key, names: values.map(\.name)))
        let terminal = try await link.start(["sh", receiverAt, ticketAt])
        let outcome: Result<String, any Error>
        do {
            let opened = try await link.waitFor(terminal, "\(ready) \(nonce)|\(error) [a-z-]+", waitSeconds)
            // The go-ahead must be the receiver's last word: an error after it means it already gave up.
            guard answer(opened, ready: true) == "\(ready) \(nonce)" else { throw DeliveryFailed(reason: code(opened)) }
            try await link.type(terminal, typed)
            // The answer carries a token only the receiver can make (it needs the key): an OK another
            // client typed onto the screen earlier never matches.
            outcome = .success(try await link.waitFor(terminal, "\(ok) \(values.count) \(okToken(key: key, count: values.count))|\(error) [a-z-]+", waitSeconds))
        } catch {
            outcome = .failure(error)
        }
        // Closed on every path, once: the receiver has ended, or is ended with its terminal.
        await link.close(terminal)
        let done = try outcome.get()
        guard answer(done) == "\(ok) \(values.count) \(okToken(key: key, count: values.count))" else { throw DeliveryFailed(reason: code(done)) }
        return values.count
    }

    /// The receiver's proof of success: the first 128 bits (32 hex digits) of SHA-256 of the key,
    /// `\nok ` and the count it wrote, so its whole line fits a narrow (60-column) terminal unwrapped.
    static func okToken(key: String, count: Int) -> String {
        String(SHA256.hash(data: Data("\(key)\nok \(count)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The receiver's terminal: wide enough that no marker line wraps, whatever the person's panes are.
    public static let terminalColumns = 120

    /// 32 random hex digits (128 bits).
    public static func randomHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// The receiver's error code on `screen`, or `unexpected`.
    static func code(_ screen: String) -> String {
        guard let line = answer(screen), line.hasPrefix(error + " ") else { return "unexpected" }
        let code = String(line.dropFirst(error.count + 1))
        return errorCodes.contains(code) ? code : "unexpected"
    }

    /// The receiver's last answer line on `screen`.
    static func answer(_ screen: String, ready includeReady: Bool = false) -> String? {
        screen.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix(ok) || $0.hasPrefix(error) || (includeReady && $0.hasPrefix(ready)) }
    }

    /// The most base64 the receiver reads (its `too-large`).
    public static let maxPayloadBytes = 4 << 20

    /// The receiver (`~/.cmux/machine-config/receive-secrets`, run with `sh`). It replaces the whole
    /// file, so a removed or renamed secret goes too; the payload stays in a 0700 temporary folder
    /// that is removed on every exit. It needs nothing but sh, stty, base64, mktemp and sha256sum or shasum.
    public static let receiver = #"""
        #!/bin/sh
        # cmux secret receiver, written by the cmux app (cmux cloud deliver-secrets). Values arrive
        # typed over the app's daemon link with echo off; they never reach the screen, argv or a log.
        set -u
        umask 077
        # The ticket (the app's nonce, its payload key and the names it sends, never a value) is read and
        # removed first: no environment, argv, screen or terminal receipt holds them.
        ticket=${1:-} nonce= mackey= names=
        if [ -n "$ticket" ] && [ -f "$ticket" ] && [ ! -L "$ticket" ]; then
          { IFS= read -r nonce && IFS= read -r mackey && IFS= read -r names; } < "$ticket" || nonce=
        fi
        [ -n "$ticket" ] && rm -f "$ticket"
        out="$HOME/.config/cmux/machine-secrets.env"
        mkdir -p "${out%/*}" && chmod 700 "${out%/*}" || { echo "CMUX-SECRETS-ERR mkdir"; exit 1; }
        # Beside the file, so the final rename is atomic and nothing lands in a shared /tmp.
        tmp=$(mktemp -d "${out%/*}/.secrets.XXXXXX") || { echo "CMUX-SECRETS-ERR mktemp"; exit 1; }
        # A sender that never finishes (the Mac went away) does not keep this receiver or its terminal.
        # It holds no terminal, and its sleep ends with it.
        ( sleep 120 & s=$!; trap 'kill "$s" 2>/dev/null; exit 0' TERM; wait "$s" && kill -TERM $$ 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        watchdog=$!
        # Echo stays off on every exit: the terminal is closed after, and a payload typed into it after
        # an early exit (another client sent EOF) never shows.
        cleanup() { kill "$watchdog" 2>/dev/null; rm -rf "$tmp"; }
        trap cleanup EXIT
        trap 'echo "CMUX-SECRETS-ERR interrupted"; exit 1' INT HUP TERM
        stty -echo 2>/dev/null || { echo "CMUX-SECRETS-ERR no-tty"; exit 1; }
        # SHA-256 and base64 decoding as Linux (coreutils) or macOS (shasum, base64 -D) spell them.
        digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
        unbase64() { if printf 'eA==' | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi; }
        case "$nonce" in ''|*[!0-9A-Fa-f]*) echo "CMUX-SECRETS-ERR nonce"; exit 1 ;; esac
        case "$mackey" in ''|*[!0-9A-Fa-f]*) echo "CMUX-SECRETS-ERR nonce"; exit 1 ;; esac
        echo "CMUX-SECRETS-READY $nonce"
        bytes=0
        : > "$tmp/b64"
        mac=""
        while IFS= read -r line; do
          [ "$line" = "CMUX-SECRETS-END $mackey" ] && break
          case "$line" in "CMUX-SECRETS-MAC "*) mac=${line#CMUX-SECRETS-MAC }; continue ;; esac
          bytes=$((bytes + ${#line}))
          [ "$bytes" -gt 4194304 ] && { echo "CMUX-SECRETS-ERR too-large"; exit 1; }
          printf '%s\n' "$line" >> "$tmp/b64" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        done
        [ "${line:-}" = "CMUX-SECRETS-END $mackey" ] || { echo "CMUX-SECRETS-ERR eof"; exit 1; }
        # Only what the app typed: the key never reached a screen, so nobody else could make this match.
        want=$({ printf '%s\n' "$mackey"; cat "$tmp/b64"; } | digest | cut -d' ' -f1)
        [ -n "$mac" ] && [ "$mac" = "$want" ] || { echo "CMUX-SECRETS-ERR bad-mac"; exit 1; }
        unbase64 < "$tmp/b64" > "$tmp/pairs" 2>/dev/null || { echo "CMUX-SECRETS-ERR bad-base64"; exit 1; }
        n=0
        : > "$tmp/env"
        while IFS= read -r pair || [ -n "$pair" ]; do
          key=${pair%%=*}
          value=${pair#*=}
          case "$key" in ''|[0-9]*|*[!A-Za-z0-9_]*) echo "CMUX-SECRETS-ERR bad-name"; exit 1 ;; esac
          [ "$key" = "$pair" ] && { echo "CMUX-SECRETS-ERR bad-line"; exit 1; }
          case " $names " in *" $key "*) ;; *) echo "CMUX-SECRETS-ERR bad-name"; exit 1 ;; esac
          grep -q "^export $key=" "$tmp/env" && { echo "CMUX-SECRETS-ERR duplicate"; exit 1; }
          quoted=$(printf '%s' "$value" | sed "s/'/'\\\\''/g") || { echo "CMUX-SECRETS-ERR write"; exit 1; }
          printf "export %s='%s'\n" "$key" "$quoted" >> "$tmp/env" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
          n=$((n + 1))
        done < "$tmp/pairs"
        # Complete or nothing: the file that replaces the old set must hold every line it was sent.
        [ "$(grep -c '^export ' "$tmp/env")" -eq "$n" ] || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        # No larger than the applier reads (it would neither mask nor source a larger one).
        [ "$(wc -c < "$tmp/env")" -le 4194304 ] || { echo "CMUX-SECRETS-ERR too-large"; exit 1; }
        chmod 600 "$tmp/env" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        sync "$tmp/env" 2>/dev/null || true
        mv -f "$tmp/env" "$out" || { echo "CMUX-SECRETS-ERR write"; exit 1; }
        # Proof that this receiver, which holds the key, wrote the set: an OK typed by anyone else lacks it.
        tok=$(printf '%s\nok %s' "$mackey" "$n" | digest | cut -c1-32)
        echo "CMUX-SECRETS-OK $n $tok"
        """#
}
