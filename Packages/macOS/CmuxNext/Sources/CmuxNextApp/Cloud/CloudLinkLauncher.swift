import CmuxNextControl
import CmuxNextDaemon
import Foundation
import os

/// Runs this Mac's `cmux link` for the Cloud app server (cx-rtipa S3): the
/// app starts it on demand with `cmux-tui link ensure` (the same model as
/// the session daemon's `server ensure`: a detached process that survives
/// the app), tells the daemon with `apps-link-changed` so the Cloud server
/// sees the new link at once, and stops it at sign-out (`link stop`, which
/// signals only the registered pid). Nothing else starts or stops the link.
///
/// Isolation: a tagged DEV build gives the link its tag's state directory
/// (`CMUX_TUI_STATE_DIR`, as ``DaemonLauncher`` does for the daemon), so its
/// registration, socket and key never meet another build's link; it binds
/// any free UDP port (`--port 0`) and reads no `~/.config/cmux/server.json`
/// (the tag's own `server.json`, normally absent).
nonisolated struct CloudLinkLauncher: Sendable {
    /// What `link ensure` answered.
    struct Ensured: Decodable, Equatable, Sendable {
        /// `running`, `started` or `restarted`.
        var status: String
        var pid: Int32?
        var socket: String?
    }

    enum Failure: Error, Equatable {
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

    init(binary: URL, stateRoot: URL?, runtimeBase: URL = DaemonLauncher.userTemporaryDirectory(), tagged: Bool,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.binary = binary
        self.stateRoot = stateRoot
        self.runtimeBase = runtimeBase
        self.tagged = tagged
        self.clock = clock
    }

    /// This app's launcher: the bundled `cmux-tui` and the launch tag's state.
    static func forApp(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> CloudLinkLauncher? {
        guard let binary = try? DaemonLauncher.resolveBinary(bundle: bundle, environment: environment) else { return nil }
        let tag = LaunchIdentity.current().tag
        return CloudLinkLauncher(binary: binary, stateRoot: tag.map { DaemonLauncher.tagStateDirectory(tag: $0) }, tagged: tag != nil)
    }

    /// The link's state directory.
    var stateDirectory: URL? { stateRoot?.appendingPathComponent("link", isDirectory: true) }

    /// The `link ensure` command line for `install` (pure).
    func ensureArguments(install: String) -> [String] {
        var arguments = ["link", "ensure", "--install", install, "--handoff"]
        if let stateDirectory { arguments += ["--state-dir", stateDirectory.path] }
        if tagged, let stateRoot {
            arguments += ["--port", "0", "--server-config", stateRoot.appendingPathComponent("server.json").path]
        }
        return arguments
    }

    func stopArguments() -> [String] {
        ["link", "stop"] + (stateDirectory.map { ["--state-dir", $0.path] } ?? [])
    }

    /// The link's environment: the app's own, with the state root and the
    /// fixed runtime base.
    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if let stateRoot { environment["CMUX_TUI_STATE_DIR"] = stateRoot.path }
        environment["XDG_RUNTIME_DIR"] = nil
        environment["TMPDIR"] = runtimeBase.path
        return environment
    }

    /// Starts the link unless one of this build runs. Off the main actor.
    @concurrent func ensure(install: String) async throws -> Ensured {
        let result = try await run(ensureArguments(install: install))
        guard let ensured = try? JSONDecoder().decode(Ensured.self, from: Self.lastLine(result.stdout)) else {
            throw Failure.badAnswer
        }
        if ensured.status != "running" {
            Self.logger.info("cloud link \(ensured.status, privacy: .public) pid \(ensured.pid ?? 0)")
        }
        return ensured
    }

    /// Stops the link (sign-out). A failure is logged only.
    @concurrent func stop() async {
        do {
            _ = try await run(stopArguments())
        } catch {
            Self.logger.error("cloud link stop failed: \(String(describing: error), privacy: .public)")
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
