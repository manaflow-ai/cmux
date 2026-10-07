import CmuxNextCloud
import CryptoKit
public import Foundation
import os

/// Per-installation SSH link state: the cmux-tui client identity and
/// known-daemon records (owner-only), the download cache, and short link
/// socket paths. Namespaced by bundle id like Cloud's state.
public struct SSHPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard(bundleID: String?) -> SSHPaths {
        SSHPaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux", isDirectory: true)
            .appendingPathComponent(bundleID ?? "cmux", isDirectory: true)
            .appendingPathComponent("ssh-next", isDirectory: true))
    }

    public var clientState: URL { root.appendingPathComponent("link-state", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// The link's local v12 socket, short enough for `sun_path`.
    public func linkSocket(machineID: String) -> String {
        let hash = SHA256.hash(data: Data((root.path + machineID).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("cmux-ssh-\(hash).sock")
    }

    public func prepare() throws {
        for directory in [root, clientState, downloads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

/// Why ``SSHMachineLink/socketPath()`` did not return a socket.
public enum SSHLinkError: Error, Sendable, CustomStringConvertible {
    /// The machine waits for the user; see `status`.
    case blocked(SSHConnectionMachine.Status)
    case ssh(SSHFailure)
    case needsInstall(InstallNeed)
    case linkFailed(String)
    case stopped

    /// Retrying on a timer cannot help; the next try waits for an event.
    public var waitsForUser: Bool {
        switch self {
        case .blocked, .needsInstall, .stopped: true
        case .ssh(let failure): failure.kind == .authFailed || failure.kind == .hostKeyUntrusted
        case .linkFailed: false
        }
    }

    public var description: String {
        switch self {
        case .blocked(let status): "waiting: \(status)"
        case .ssh(let failure): failure.message
        case .needsInstall(let need): "cmux-tui needs an install: \(need)"
        case .linkFailed(let text): text
        case .stopped: "disconnected"
        }
    }
}

/// One SSH machine's link: probes the machine over the user's ssh, then
/// runs the bundled `cmux-tui remote connect ssh://…` (SSHCommandLine) and
/// returns its local v12 socket, which the app connects a
/// `DaemonConnection` to exactly like a Cloud machine's link.
///
/// ``socketPath()`` is the connection's endpoint provider: it returns the
/// live socket or starts a new link, gated by the machine's
/// ``SSHConnectionMachine``. Every status change is reported through
/// `onStatus` (the App shows it in the sidebar).
public actor SSHMachineLink {
    public nonisolated let host: SSHHost
    public nonisolated let machineID: String
    private let binary: URL
    private let paths: SSHPaths
    private let commandLine: SSHCommandLine
    private let environment: @Sendable () async -> [String: String]
    private let onStatus: @Sendable (SSHConnectionMachine.Status) -> Void
    private var machine = SSHConnectionMachine()
    private var child: ChildProcess?
    private var socket: String?
    private var starting: Task<String, any Error>?
    private var localProtocol: Int?
    /// The last probe's findings (platform for the installer).
    public private(set) var lastReport: SSHProbeReport?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "ssh.link")

    public init(host: SSHHost, binary: URL, paths: SSHPaths, commandLine: SSHCommandLine = SSHCommandLine(),
                environment: @escaping @Sendable () async -> [String: String],
                onStatus: @escaping @Sendable (SSHConnectionMachine.Status) -> Void) {
        self.host = host
        machineID = host.machineID
        self.binary = binary
        self.paths = paths
        self.commandLine = commandLine
        self.environment = environment
        self.onStatus = onStatus
    }

    public var status: SSHConnectionMachine.Status { machine.status }
    public var pid: Int32? { child?.pid }

    /// Feeds an event to the gate and reports the status.
    public func handle(_ event: SSHConnectionMachine.Event) {
        let before = machine.status
        machine.handle(event)
        if event == .disconnect { tearDown() }
        if machine.status != before { onStatus(machine.status) }
    }

    public func socketPath() async throws -> String {
        if let socket, child?.isRunning == true, FileManager.default.fileExists(atPath: socket) { return socket }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Ends the link for good (forget, quit).
    public func stop() {
        handle(.disconnect)
    }

    private func tearDown() {
        child?.terminate()
        child = nil
        socket = nil
    }

    private func start() async throws -> String {
        tearDown()
        handle(.attemptStarted)
        guard machine.mayAttempt else { throw SSHLinkError.blocked(machine.status) }
        let env = await environment()
        let report = try await probe(env)
        guard machine.mayAttempt else { throw SSHLinkError.stopped }
        let need = InstallNeed.assess(report, localProtocol: try await bundledProtocol(env))
        guard need == .none else {
            handle(.probed(need))
            throw SSHLinkError.needsInstall(need)
        }
        return try await spawn(env)
    }

    /// One ssh round trip: platform and the machine's cmux-tui.
    public func probe(_ env: [String: String]) async throws -> SSHProbeReport {
        let result: SSHProcessResult
        do {
            result = try await SSHProcessRunner.run(commandLine.script(host), input: .data(Data(SSHProbeReport.script(remoteBinary: host.remoteBinary).utf8)),
                                                 environment: env, deadline: .seconds(45), label: "ssh probe \(host.destination)")
        } catch is DeadlineExceeded {
            let failure = SSHFailure.unreachable("ssh to \(host.destination) did not answer within 45 s")
            handle(.failed(failure))
            throw SSHLinkError.ssh(failure)
        }
        if let failure = SSHFailure.classify(status: result.status, stderr: result.stderr), result.status == 255 {
            handle(.failed(failure))
            throw SSHLinkError.ssh(failure)
        }
        guard let report = SSHProbeReport.parse(stdout: result.stdout) else {
            let failure = SSHFailure.classify(status: result.status == 0 ? 1 : result.status, stderr: result.stderr)
                ?? .remoteFailed("the remote shell gave no probe output")
            handle(.failed(failure))
            throw SSHLinkError.ssh(failure)
        }
        lastReport = report
        return report
    }

    /// The bundled cmux-tui's link protocol, read once.
    private func bundledProtocol(_ env: [String: String]) async throws -> Int {
        if let localProtocol { return localProtocol }
        let result = try await SSHProcessRunner.run([binary.path, "remote-probe", "--json"], environment: env, deadline: .seconds(10),
                                                 label: "cmux-tui remote-probe")
        let value = try RemoteProbe.decode(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).remoteProtocol
        localProtocol = value
        return value
    }

    private func spawn(_ env: [String: String]) async throws -> String {
        try paths.prepare()
        let path = paths.linkSocket(machineID: machineID)
        unlink(path)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw SSHLinkError.linkFailed("cmux-tui not found at \(binary.path)")
        }
        let child = ChildProcess(executable: binary,
                                 arguments: commandLine.link(host, clientStateDir: paths.clientState.path, localSocket: path),
                                 environment: env)
        try child.start()
        self.child = child
        do {
            let socket = try await child.firstLine(within: .seconds(60), label: "cmux-tui remote connect \(host.destination)") { line in
                if case .connected(let socket) = CloudLinkEvent.parse(line) { return socket }
                return nil
            }
            guard machine.mayAttempt, self.child === child else {
                child.terminate()
                throw SSHLinkError.stopped
            }
            self.socket = socket
            handle(.linkUp)
            watchExit(child)
            logger.info("ssh link up for \(self.host.destination.description, privacy: .public) pid \(child.pid ?? 0)")
            return socket
        } catch let error as SSHLinkError {
            throw error
        } catch {
            child.terminate()
            if self.child === child { self.child = nil }
            let stderr = child.stderrText
            let failure = SSHFailure.classify(status: 255, stderr: stderr) ?? .remoteFailed(String(describing: error))
            logger.error("ssh link for \(self.host.destination.description, privacy: .public) failed: \(stderr, privacy: .public)")
            handle(.failed(failure))
            throw SSHLinkError.ssh(failure)
        }
    }

    /// A link that exits (the network is gone past its own retries, the
    /// machine rebooted) reports it; the daemon connection's reconnect then
    /// calls ``socketPath()``, which probes again.
    private func watchExit(_ child: ChildProcess) {
        Task { [weak self] in
            _ = await child.waitForExit()
            await self?.linkExited(child)
        }
    }

    private func linkExited(_ exited: ChildProcess) {
        guard child === exited else { return }
        child = nil
        socket = nil
        handle(.linkLost)
    }
}
