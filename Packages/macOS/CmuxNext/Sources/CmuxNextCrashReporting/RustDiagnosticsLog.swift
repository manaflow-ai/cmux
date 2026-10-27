public import Foundation

/// One family of JSONL files a cmux Rust process writes for the app to forward (p09-observability-075): where
/// they are, which process wrote them, and whether each line is a panic (`cmux-panic-log`) or a hang
/// (`cmux-hang-watch`'s `hangs-<pid>.jsonl`, schema 1).
///
/// ``all(_:)`` is the one list of every shipped role's logs; a Rust process writes its logs where it says.
public struct RustDiagnosticsLog: Sendable, Equatable {
    /// What one line of the log is.
    public enum Kind: String, Sendable, Equatable {
        /// A `cmux-panic-log` record: one panic.
        case panic
        /// A `cmux-hang-watch` record: one scope still open past its deadline.
        case hang
    }

    /// Which files of ``directory`` belong to the log.
    public enum Name: Sendable, Equatable {
        /// One file of exactly this name.
        case exact(String)
        /// Every file whose name has this prefix and suffix (one file per process: `hangs-<pid>.jsonl`).
        case pattern(prefix: String, suffix: String)

        /// Whether a file named `name` is one of the log's.
        public func matches(_ name: String) -> Bool {
            switch self {
            case .exact(let exact): name == exact
            case .pattern(let prefix, let suffix):
                name.count >= prefix.count + suffix.count && name.hasPrefix(prefix) && name.hasSuffix(suffix)
            }
        }
    }

    /// The folder the files are in.
    public var directory: URL
    /// Which of its files are the log's.
    public var name: Name
    /// Which process wrote them.
    public var source: RustPanicSource
    /// What each line is.
    public var kind: Kind
    /// Whether the app may make ``directory`` to watch it before its process does. False for a folder another
    /// process owns with its own mode: the holder refuses a `/tmp/cmux-hd-<uid>` that is not 0700, and
    /// `/Library/Logs` is root's. Such a log is read when the app starts and, once its folder exists, as it grows.
    public var createsDirectory: Bool

    /// Makes the value from its parts.
    public init(directory: URL, name: Name, source: RustPanicSource, kind: Kind, createsDirectory: Bool = true) {
        self.directory = directory
        self.name = name
        self.source = source
        self.kind = kind
        self.createsDirectory = createsDirectory
    }

    /// The log that is exactly `file`.
    public static func file(_ file: URL, source: RustPanicSource, kind: Kind) -> RustDiagnosticsLog {
        RustDiagnosticsLog(directory: file.deletingLastPathComponent(), name: .exact(file.lastPathComponent),
                           source: source, kind: kind)
    }

    /// The log's files that exist now, in name order.
    public func files(fileManager: FileManager = .default) -> [URL] {
        switch name {
        case .exact(let exact):
            let file = directory.appending(path: exact)
            return fileManager.fileExists(atPath: file.path) ? [file] : []
        case .pattern:
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter(name.matches).sorted().map { directory.appending(path: $0) }
        }
    }

    /// The folders the roles write into.
    public struct Roots: Sendable, Equatable {
        /// The owner's state root (the parent of its sessions folder): the daemon's panic log and every other
        /// user-level process's logs.
        public var stateRoot: URL
        /// The app's cmux-tui session (`owner-panics-<session>.jsonl`).
        public var session: String
        /// The acpmux daemon's `ACPMUX_HOME`; nil with no acpmux.
        public var acpmuxHome: URL?
        /// The holders' folder (`/tmp/cmux-hd-<uid>`): a holder outlives the app's state root choice.
        public var holderDirectory: URL
        /// The root server helper's folder (`/Library/Logs/<bundle id>/server-helper`): it runs as root, so it
        /// never writes into a user's home.
        public var serverHelperDirectory: URL

        /// Makes the value from its parts.
        public init(stateRoot: URL, session: String, acpmuxHome: URL?, holderDirectory: URL, serverHelperDirectory: URL) {
            self.stateRoot = stateRoot
            self.session = session
            self.acpmuxHome = acpmuxHome
            self.holderDirectory = holderDirectory
            self.serverHelperDirectory = serverHelperDirectory
        }

        /// The roots of the app with bundle id `bundleID`.
        public static func app(stateRoot: URL, session: String, acpmuxHome: URL?, bundleID: String?,
                               uid: UInt32 = getuid()) -> Roots {
            Roots(stateRoot: stateRoot, session: session, acpmuxHome: acpmuxHome,
                  holderDirectory: URL(filePath: "/tmp/cmux-hd-\(uid)", directoryHint: .isDirectory),
                  serverHelperDirectory: URL(filePath: "/Library/Logs", directoryHint: .isDirectory)
                      .appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "server-helper"))
        }
    }

    /// One shipped role: its source and the stem its files are named by (cmux-trace's `Role::as_str` where the role
    /// has a ring).
    private struct Role {
        let source: RustPanicSource
        let stem: String
    }

    /// The user-level roles whose panic log is `<stateRoot>/<stem>-panics-<pid>.jsonl` (tasks 099 and 100).
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

    /// Every shipped role's logs (tasks 095, 099 and 100):
    ///
    /// | Role | Panics | Hangs |
    /// | --- | --- | --- |
    /// | daemon (the owner) | `<stateRoot>/owner-panics-<session>.jsonl` | `<stateRoot>/hangs/daemon/hangs-<pid>.jsonl` |
    /// | acpmux | `<acpmuxHome>/panics.jsonl` | `<acpmuxHome>/hangs/acpmux/hangs-<pid>.jsonl` |
    /// | holder | `<holderDirectory>/holder-panics*.jsonl` | `<holderDirectory>/hangs/holder/hangs-<pid>.jsonl` |
    /// | server helper | `<serverHelperDirectory>/server-helper-panics*.jsonl` | `<serverHelperDirectory>/hangs/hangs-<pid>.jsonl` |
    /// | every other role | `<stateRoot>/<stem>-panics-<pid>.jsonl` | `<stateRoot>/hangs/<stem>/hangs-<pid>.jsonl` |
    ///
    /// A hang file is named by pid only (`cmux_hang_watch::init(dir)`), so each role has its own hang folder.
    public static func all(_ roots: Roots) -> [RustDiagnosticsLog] {
        let hangs = Name.pattern(prefix: "hangs-", suffix: ".jsonl")
        func hangLog(_ directory: URL, _ source: RustPanicSource, createsDirectory: Bool = true) -> RustDiagnosticsLog {
            RustDiagnosticsLog(directory: directory, name: hangs, source: source, kind: .hang, createsDirectory: createsDirectory)
        }
        let roleHangs = roots.stateRoot.appending(path: "hangs", directoryHint: .isDirectory)
        var logs = [
            RustDiagnosticsLog(directory: roots.stateRoot, name: .exact("owner-panics-\(roots.session).jsonl"),
                               source: .owner, kind: .panic),
            hangLog(roleHangs.appending(path: "daemon"), .owner),
            RustDiagnosticsLog(directory: roots.holderDirectory, name: .pattern(prefix: "holder-panics", suffix: ".jsonl"),
                               source: .holder, kind: .panic, createsDirectory: false),
            hangLog(roots.holderDirectory.appending(path: "hangs").appending(path: "holder"), .holder, createsDirectory: false),
            RustDiagnosticsLog(directory: roots.serverHelperDirectory,
                               name: .pattern(prefix: "server-helper-panics", suffix: ".jsonl"),
                               source: .serverHelper, kind: .panic, createsDirectory: false),
            hangLog(roots.serverHelperDirectory.appending(path: "hangs"), .serverHelper, createsDirectory: false),
        ]
        if let home = roots.acpmuxHome {
            logs.append(.file(RustPanicSource.acpmuxLog(acpmuxHome: home), source: .acpmux, kind: .panic))
            logs.append(hangLog(home.appending(path: "hangs").appending(path: "acpmux"), .acpmux))
        }
        for role in stateRootRoles {
            logs.append(RustDiagnosticsLog(directory: roots.stateRoot, name: .pattern(prefix: "\(role.stem)-panics-", suffix: ".jsonl"),
                                           source: role.source, kind: .panic))
            logs.append(hangLog(roleHangs.appending(path: role.stem), role.source))
        }
        return logs
    }
}
