public import CmuxNextCompat
public import Foundation
import os

/// Runs this Mac's `cmux link` for the Cloud app server (cx-rtipa S3): the
/// app starts it on demand with `cmux-tui link ensure` (the same model as
/// the session daemon's `server ensure`: a detached process that survives
/// the app), tells the daemon with `apps-link-changed` so the Cloud server
/// sees the new link at once, and stops it at sign-out (`link stop`, which
/// signals only the registered pid). Nothing else starts or stops the link.
///
/// Isolation: a tagged DEV build (any build with its own names) gives the link its daemon's state directory
/// (`CMUX_TUI_STATE_DIR`, as ``DaemonLauncher`` does for the daemon), so its
/// registration, socket and key never meet another build's link; it binds
/// any free UDP port (`--port 0`) and reads no `~/.config/cmux/server.json`
/// (the tag's own `server.json`, normally absent).
public nonisolated struct CloudLinkLauncher: Sendable {
    /// What `link ensure` answered.
    public struct Ensured: Decodable, Equatable, Sendable {
        /// `running`, `started` or `restarted`.
        public var status: String
        public var pid: Int32?
        public var socket: String?
    }

    public enum Failure: Error, Equatable {
        /// The command failed; `detail` is its last stderr line.
        case failed(String)
        case badAnswer
    }

    let binary: URL
    /// The daemon state root (`CMUX_TUI_STATE_DIR`); nil = cmux-tui's default.
    let stateRoot: URL?
    /// `TMPDIR` for the link (``DaemonLauncher/userTemporaryDirectory()``),
    /// so the socket does not move with the app's launch environment.
    let runtimeBase: URL
    let tagged: Bool
    private let clock: any Clock<Duration>

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")
    private static let timeout: Duration = .seconds(30)

    public init(binary: URL, stateRoot: URL?, runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(), tagged: Bool,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.binary = binary
        self.stateRoot = stateRoot
        self.runtimeBase = runtimeBase
        self.tagged = tagged
        self.clock = clock
    }

    /// This app's launcher: only the app bundle's own `bin/cmux-tui` (never
    /// a `CMUX_NEXT_TUI_BIN` override) and its build's state: a kept tag's
    /// (`tags/<tag>/tui`), names of the build key (`builds/<key>/tui`, as the
    /// daemon's, per-build isolation S3), else cmux-tui's default root
    /// (release, the untagged channels). A DEBUG build without its own state
    /// gets no link: it would share the release app's state directory.
    public static func forApp(bundle: Bundle = .main, build: BuildIdentity) -> CloudLinkLauncher? {
        guard let resources = bundle.resourceURL else { return nil }
        let binary = resources.appendingPathComponent("bin/cmux-tui")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        let own = build.keepsAppNames
            ? build.tag.map { DaemonLauncher.tagStateDirectory(tag: $0) }
            : DaemonLauncher.appNames(build: build).stateDirectory
        #if DEBUG
        guard own != nil else { return nil }
        #endif
        let stateRoot = own ?? defaultStateRoot()
        guard let stateRoot else { return nil }
        return CloudLinkLauncher(binary: binary, stateRoot: stateRoot, tagged: own != nil)
    }

    /// cmux-tui's default daemon state root on macOS
    /// (`~/Library/Application Support/cmux-tui/sessions`), named explicitly
    /// so `--state-dir` is always given.
    static func defaultStateRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux-tui/sessions", isDirectory: true)
    }

    /// The link's state directory.
    var stateDirectory: URL? { stateRoot?.appendingPathComponent("link", isDirectory: true) }

    /// The `link ensure` command line for `install` (pure). `--handoff`
    /// goes only with an explicit `--state-dir`.
    func ensureArguments(install: String) -> [String] {
        guard let stateDirectory else { return ["link", "ensure", "--install", install] }
        var arguments = ["link", "ensure", "--install", install, "--handoff", "--state-dir", stateDirectory.path]
        if tagged, let stateRoot {
            arguments += ["--port", "0", "--server-config", stateRoot.appendingPathComponent("server.json").path]
        }
        return arguments
    }

    func stopArguments() -> [String] {
        ["link", "stop"] + (stateDirectory.map { ["--state-dir", $0.path] } ?? [])
    }

    /// `link archive`: after a sign-out, the signed-out install's key and
    /// peers go into its archive and the config goes, so no later ensure
    /// without `--install` starts the link as that account.
    func archiveArguments() -> [String] {
        ["link", "archive"] + (stateDirectory.map { ["--state-dir", $0.path] } ?? [])
    }

    /// The variables the link may get from the app's environment; nothing
    /// else (no `CMUX_NEXT_*`, no `DYLD_*`, no credentials) reaches it.
    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "SHELL"]

    /// The link's environment: the allow-listed variables of `base`, the
    /// state root and the fixed runtime base.
    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter { Self.inheritedKeys.contains($0.key) }
        if let stateRoot { environment["CMUX_TUI_STATE_DIR"] = stateRoot.path }
        environment["TMPDIR"] = runtimeBase.path
        return environment
    }

    /// Starts the link unless one of this build runs. Off the main actor.
    @concurrent public func ensure(install: String) async throws -> Ensured {
        let result = try await run(ensureArguments(install: install))
        guard let ensured = try? JSONDecoder().decode(Ensured.self, from: Self.lastLine(result.stdout)) else {
            throw Failure.badAnswer
        }
        if ensured.status != "running" {
            Self.logger.info("cloud link \(ensured.status, privacy: .public) pid \(ensured.pid ?? 0)")
        }
        return ensured
    }

    /// Stops the link (sign-out, session end, policy). A failure is logged
    /// with the install id only (the old config then stays).
    @concurrent public func stop(install: String? = nil) async {
        do {
            _ = try await run(stopArguments())
        } catch {
            Self.logger.error("cloud link stop failed for install \(install ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Archives the signed-out install's key and peers (`link archive`). A
    /// failure is logged only.
    @concurrent public func archive(install: String? = nil) async {
        do {
            _ = try await run(archiveArguments())
        } catch {
            Self.logger.error("cloud link archive failed for install \(install ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: environment(),
                                                 timeout: Self.timeout, clock: clock)
        guard result.status == 0 else {
            let detail = String(decoding: Self.lastLine(result.stderr), as: UTF8.self)
            throw Failure.failed(detail)
        }
        return result
    }

    static func lastLine(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return Data(line.utf8)
    }
}
