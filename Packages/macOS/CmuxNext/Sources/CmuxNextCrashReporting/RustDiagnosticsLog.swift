import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
public import Foundation

/// One family of JSONL files a cmux Rust process writes for the app to forward: where
/// they are, which process wrote them, and whether each line is a panic (`cmux-panic-log`) or a hang
/// (`cmux-hang-watch`'s `hangs-<pid>.jsonl`, schema 1).
///
/// ``all(_:)`` is the one list of every shipped role's logs, each at the folder its writer uses.
public struct RustDiagnosticsLog: Sendable, Equatable {
    /// What one line of the log is.
    public enum Kind: String, Sendable, Equatable {
        /// A `cmux-panic-log` record: one panic.
        case panic
        /// A `cmux-hang-watch` record: one scope still open past its deadline.
        case hang
    }

    /// Which entries of a folder belong to the log.
    public enum Name: Sendable, Equatable {
        /// One entry of exactly this name.
        case exact(String)
        /// Every entry whose name has this prefix and suffix (one per process: `hangs-<pid>.jsonl`).
        case pattern(prefix: String, suffix: String)

        /// Whether an entry named `name` is one of the log's.
        public func matches(_ name: String) -> Bool {
            switch self {
            case .exact(let exact): name == exact
            case .pattern(let prefix, let suffix):
                name.count >= prefix.count + suffix.count && name.hasPrefix(prefix) && name.hasSuffix(suffix)
            }
        }
    }

    /// The folder the files are in, or with ``perProcessFolders`` the folder of the folders they are in.
    public var directory: URL
    /// Nil: the files are in ``directory``. Set: they are in each subfolder of ``directory`` of a matching name
    /// (a holder's `<socket>.trace`, one per holder).
    public var perProcessFolders: Name?
    /// Which files of a folder are the log's.
    public var name: Name
    /// Which process wrote them; with ``namesProcessByBlackBox``, the process when no black box names one.
    public var source: RustPanicSource
    /// What each line is.
    public var kind: Kind
    /// Whether the app may make ``directory`` to watch it before its process does. False for a folder another
    /// process owns with its own mode: the holder refuses a `/tmp/cmux-hd-<uid>` that is not 0700, and
    /// `/Library/Logs` is root's. The forwarder watches the nearest folder above such a folder that exists, and the
    /// folder itself once it appears.
    public var createsDirectory: Bool
    /// True for a folder several roles write into (the app's trace folder): a hang line's process is the role of the
    /// black box of its pid beside it (`<role>-<pid>.blackbox.cmxtrace`, ``TraceRingFile/fileName(role:pid:)``).
    public var namesProcessByBlackBox: Bool

    /// Makes the value from its parts.
    public init(directory: URL, perProcessFolders: Name? = nil, name: Name, source: RustPanicSource, kind: Kind,
                createsDirectory: Bool = true, namesProcessByBlackBox: Bool = false) {
        self.directory = directory
        self.perProcessFolders = perProcessFolders
        self.name = name
        self.source = source
        self.kind = kind
        self.createsDirectory = createsDirectory
        self.namesProcessByBlackBox = namesProcessByBlackBox
    }

    /// The log that is exactly `file`.
    public static func file(_ file: URL, source: RustPanicSource, kind: Kind) -> RustDiagnosticsLog {
        RustDiagnosticsLog(directory: file.deletingLastPathComponent(), name: .exact(file.lastPathComponent),
                           source: source, kind: kind)
    }

    /// The folders that hold the log's files now: ``directory``, or its matching subfolders (disk reads: call it off
    /// the main thread).
    public func folders() -> [URL] {
        guard let perProcessFolders else { return Self.isDirectory(directory) ? [directory] : [] }
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(perProcessFolders.matches).sorted()
            .map { directory.appending(path: $0, directoryHint: .isDirectory) }
            .filter(Self.isDirectory)
    }

    /// The log's files that exist now, in path order (disk reads: call it off the main thread).
    public func files() -> [URL] {
        folders().flatMap { folder -> [URL] in
            switch name {
            case .exact(let exact):
                let file = folder.appending(path: exact)
                return FileManager.checked.fileExists(atPath: file.path) ? [file] : []
            case .pattern:
                let names = (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? []
                return names.filter(name.matches).sorted().map { folder.appending(path: $0) }
            }
        }
    }

    /// The process that wrote the hang line of `pid` in `file`: ``source``, or with ``namesProcessByBlackBox`` the
    /// role of that pid's black box beside the file (disk reads: call it off the main thread).
    public func process(ofPID pid: UInt32, in file: URL) -> RustPanicSource {
        guard namesProcessByBlackBox else { return source }
        let folder = file.deletingLastPathComponent()
        let role = TraceRing.Role.allCases.first { role in
            FileManager.checked.fileExists(atPath: folder.appending(path: TraceRingFile.fileName(role: role, pid: pid)).path)
        }
        return role.flatMap(RustPanicSource.init(ringRole:)) ?? source
    }

    /// Whether `url` is a folder now (a disk read).
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        // SAFETY: the pointer is to a local that outlives the call.
        return unsafe FileManager.checked.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The folders the roles write into.
    public struct Roots: Sendable, Equatable {
        /// The owner's state root (the parent of its sessions folder): the daemon's panic log and every other
        /// user-level process's panic logs.
        public var stateRoot: URL
        /// The owner's sessions folder (its `CMUX_TUI_STATE_DIR`): its terminal hosts' records are in it.
        public var sessionsDirectory: URL
        /// The app's cmux-tui session (`owner-panics-<session>.jsonl`).
        public var session: String
        /// The acpmux daemon's `ACPMUX_HOME`; nil with no acpmux.
        public var acpmuxHome: URL?
        /// The app's trace folder (`~/Library/Logs/<bundle id>/trace`, ``TraceBlackBoxFileSteps/appDirectory(bundleID:home:)``):
        /// task 095 hands it to the daemon and the daemon to its hosts.
        public var traceDirectory: URL
        /// The holders' folder (`/tmp/cmux-hd-<uid>`): a holder outlives the app's state root choice.
        public var holderDirectory: URL
        /// The root server helper's folder (`/Library/Logs/<bundle id>/server-helper`): it runs as root, so it
        /// never writes into a user's home.
        public var serverHelperDirectory: URL

        /// Makes the value from its parts.
        public init(sessionsDirectory: URL, session: String, acpmuxHome: URL?, traceDirectory: URL, holderDirectory: URL,
                    serverHelperDirectory: URL) {
            self.stateRoot = sessionsDirectory.deletingLastPathComponent()
            self.sessionsDirectory = sessionsDirectory
            self.session = session
            self.acpmuxHome = acpmuxHome
            self.traceDirectory = traceDirectory
            self.holderDirectory = holderDirectory
            self.serverHelperDirectory = serverHelperDirectory
        }

        /// The roots of the app with bundle id `bundleID`.
        public static func app(sessionsDirectory: URL, session: String, acpmuxHome: URL?, bundleID: String?,
                               uid: UInt32 = getuid(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Roots {
            Roots(sessionsDirectory: sessionsDirectory, session: session, acpmuxHome: acpmuxHome,
                  traceDirectory: TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID, home: home),
                  holderDirectory: URL(filePath: "/tmp/cmux-hd-\(uid)", directoryHint: .isDirectory),
                  serverHelperDirectory: URL(filePath: "/Library/Logs", directoryHint: .isDirectory)
                      .appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "server-helper"))
        }

        /// The trace folder of this session's terminal hosts: `trace` beside their records in
        /// `<sessions>/terminal-hosts-<token>` (cmux-tui-core `terminal_host_root` and `host_trace_dir`).
        public var terminalHostTraceDirectory: URL {
            sessionsDirectory.appending(path: "terminal-hosts-\(Self.stableToken(session))", directoryHint: .isDirectory)
                .appending(path: "trace", directoryHint: .isDirectory)
        }

        /// cmux-tui-core's `stable_token`: the 64-bit FNV-1a of `value`'s UTF-8 bytes as 16 lowercase hex digits.
        static func stableToken(_ value: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            let hex = String(hash, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }
    }

    /// One shipped role: its source and the stem its panic files are named by.
    private struct Role {
        let source: RustPanicSource
        let stem: String
    }

    /// The user-level roles whose panic log is `<stateRoot>/<stem>-panics*.jsonl` (tasks 099 and 100): one file per
    /// process (`<stem>-panics-<pid>.jsonl`) or one every process of the role appends to (`<stem>-panics.jsonl`:
    /// cmux-tui-core `HelperPanicLog`, the app hosts', the browser host's and `cmux mcp serve`'s).
    private static let stateRootRoles: [Role] = [
        Role(source: .terminalHost, stem: "terminal-host"),
        Role(source: .agentHost, stem: "agent-host"),
        Role(source: .appHost, stem: "app-host"),
        Role(source: .browserHost, stem: "browser-host"),
        Role(source: .mcp, stem: "mcp"),
        Role(source: .cloud, stem: "cloud"),
        Role(source: .optchatChief, stem: "optchat-chief"),
        Role(source: .diffSidecar, stem: "diff-sidecar"),
    ]

    /// Every shipped role's logs (tasks 074, 095, 099 and 100). A hang file is `hangs-<pid>.jsonl` in the folder the
    /// process passes `cmux_hang_watch::init`:
    ///
    /// | Role | Panics | Hangs |
    /// | --- | --- | --- |
    /// | daemon (the owner) | `<stateRoot>/owner-panics-<session>.jsonl` | the trace folder |
    /// | acpmux | `<acpmuxHome>/panics.jsonl` | `<acpmuxHome>/hangs-<pid>.jsonl` (acpmux `daemon::hang_watch::init(home)`) |
    /// | acpmux agent host | `<acpmuxHome>/agent-host-panics.jsonl` (acpmux `agent_host::panic_log_path`) | the trace folder |
    /// | holder | `<holderDirectory>/holder-panics*.jsonl` | `<holderDirectory>/<socket>.trace/hangs-<pid>.jsonl` (cmux-holder `run`) |
    /// | terminal host | `<stateRoot>/terminal-host-panics-<pid>.jsonl` | ``Roots/terminalHostTraceDirectory`` (`start_process_hang_watch`), and the trace folder |
    /// | server helper | `<serverHelperDirectory>/server-helper-panics*.jsonl` | none: it starts no hang watch |
    /// | every other role | `<stateRoot>/<stem>-panics*.jsonl` | the trace folder |
    ///
    /// The trace folder (``Roots/traceDirectory``) is task 095's folder for every process but the holder; its hang
    /// lines name their process by the black box of their pid (``namesProcessByBlackBox``), the daemon when none does.
    public static func all(_ roots: Roots) -> [RustDiagnosticsLog] {
        let hangs = Name.pattern(prefix: "hangs-", suffix: ".jsonl")
        var logs = [
            RustDiagnosticsLog(directory: roots.stateRoot, name: .exact("owner-panics-\(roots.session).jsonl"),
                               source: .owner, kind: .panic),
            RustDiagnosticsLog(directory: roots.traceDirectory, name: hangs, source: .owner, kind: .hang, namesProcessByBlackBox: true),
            RustDiagnosticsLog(directory: roots.holderDirectory, name: .pattern(prefix: "holder-panics", suffix: ".jsonl"),
                               source: .holder, kind: .panic, createsDirectory: false),
            RustDiagnosticsLog(directory: roots.holderDirectory, perProcessFolders: .pattern(prefix: "", suffix: ".trace"), name: hangs,
                               source: .holder, kind: .hang, createsDirectory: false),
            RustDiagnosticsLog(directory: roots.terminalHostTraceDirectory, name: hangs, source: .terminalHost, kind: .hang,
                               createsDirectory: false),
            RustDiagnosticsLog(directory: roots.serverHelperDirectory,
                               name: .pattern(prefix: "server-helper-panics", suffix: ".jsonl"),
                               source: .serverHelper, kind: .panic, createsDirectory: false),
        ]
        if let home = roots.acpmuxHome { logs += acpmux(home: home) }
        for role in stateRootRoles {
            logs.append(RustDiagnosticsLog(directory: roots.stateRoot, name: .pattern(prefix: "\(role.stem)-panics", suffix: ".jsonl"),
                                           source: role.source, kind: .panic))
        }
        return logs
    }

    /// The acpmux daemon's logs in its `ACPMUX_HOME`: `panics.jsonl`, its agent hosts' `agent-host-panics.jsonl` (the
    /// controller names it to each host, which gets no `ACPMUX_HOME`) and `hangs-<pid>.jsonl` (acpmux
    /// `daemon::hang_watch::init(home)`). The app finds that home with a file system read, so its launch adds these at
    /// the forwarders' first pass (``CrashForwarders``); ``all(_:)`` holds them when ``Roots/acpmuxHome`` is set.
    public static func acpmux(home: URL) -> [RustDiagnosticsLog] {
        [.file(RustPanicSource.acpmuxLog(acpmuxHome: home), source: .acpmux, kind: .panic),
         .file(RustPanicSource.agentHostLog(acpmuxHome: home), source: .agentHost, kind: .panic),
         RustDiagnosticsLog(directory: home, name: .pattern(prefix: "hangs-", suffix: ".jsonl"), source: .acpmux, kind: .hang)]
    }
}
