public import Foundation
import os

/// One Cloud machine's headless `cmux-tui remote connect` link. The link
/// dials the machine's daemon (`ws://<vpc-ip>:1337/v1/link`, trusted
/// carrier) through the WireGuard hub and exposes a local Unix socket that
/// speaks the same v12 protocol as the local daemon, so the App connects a
/// `DaemonConnection` to it and attaches terminals over it unchanged.
///
/// ``socketPath()`` is the connection's endpoint provider: it returns the
/// live socket, or (re)starts the link: fresh attach endpoint, hub socket,
/// spawn, first `connection-snapshot` within the deadline. A dead link is
/// replaced on the next call, which the connection makes on reconnect.
public actor CloudMachineLink {
    public nonisolated let machineID: String
    private let api: CloudAPIClient
    private let hub: CloudTunnelHub
    private let paths: CloudPaths
    private let binary: URL
    private let deviceName: String
    private var child: ChildProcess?
    private var socket: String?
    private var starting: Task<String, any Error>?
    private var stopped = false
    private var suspended = false
    private var generation = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.link")

    public init(machineID: String, api: CloudAPIClient, hub: CloudTunnelHub, paths: CloudPaths, binary: URL, deviceName: String) {
        self.machineID = machineID
        self.api = api
        self.hub = hub
        self.paths = paths
        self.binary = binary
        self.deviceName = deviceName
    }

    public func socketPath() async throws -> String {
        let generation = generation
        try checkGeneration(generation)
        if let socket, child?.isRunning == true, FileManager.default.fileExists(atPath: socket) { return socket }
        if let starting {
            let path = try await starting.value
            try checkGeneration(generation)
            return path
        }
        let task = Task { try await self.start(generation: generation) }
        starting = task
        defer { if self.generation == generation { starting = nil } }
        let path = try await task.value
        try checkGeneration(generation)
        return path
    }

    /// Ends the link for good (machine removed, sign-out, quit).
    public func stop() {
        stopped = true
        invalidate()
    }

    private func invalidate() {
        generation += 1
        starting?.cancel()
        starting = nil
        child?.terminate()
        child = nil
        socket = nil
    }

    /// Parks the link while its machine is paused. Unlike `stop`, parking is
    /// reversible: a later resume can start a fresh attach endpoint and socket
    /// on the same session.
    public func suspend() {
        guard !stopped else { return }
        suspended = true
        invalidate()
    }

    /// Allows a new connection after the provider reports the machine live.
    public func resume() {
        guard !stopped else { return }
        suspended = false
    }

    private func checkGeneration(_ generation: Int) throws {
        try Task.checkCancellation()
        guard !stopped, !suspended, self.generation == generation else { throw CancellationError() }
    }

    /// PID of the running link process, for diagnostics.
    public var pid: Int32? { child?.pid }

    private func start(generation: Int) async throws -> String {
        try checkGeneration(generation)
        child?.terminate()
        child = nil
        socket = nil
        // Lifecycle transitions can run during every await. A stale start
        // must never publish a socket or replace a newer link.
        let endpoint = try await api.attachEndpoint(machineID)
        try checkGeneration(generation)
        let hubSocket = try await hub.socketPath()
        try checkGeneration(generation)
        try paths.prepare()
        unlink(paths.linkSocket(machineID: machineID))
        var arguments = [
            "remote", "connect", endpoint.route,
            "--device-name", deviceName,
            "--state-dir", paths.linkState.path,
            "--local-socket", paths.linkSocket(machineID: machineID),
            "--headless", "--json", "--exit-with-parent", "--lanes", "single",
            "--connect-timeout-seconds", "20",
        ]
        if endpoint.trustedCarrier { arguments.append("--carrier") }
        arguments += ["--wireguard-hub", hubSocket]
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_REMOTE_STATE_DIR"] = paths.linkState.path
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: arguments, environment: environment)
        try child.start()
        self.child = child
        do {
            let path = try await child.firstLine(within: .seconds(60), label: "cmux-tui remote connect") { line in
                if case .connected(let socket) = CloudLinkEvent.parse(line) { return socket }
                return nil
            }
            try checkGeneration(generation)
            socket = path
            logger.info("link up for \(self.machineID, privacy: .public) pid \(child.pid ?? 0)")
            return path
        } catch {
            child.terminate()
            if self.child === child { self.child = nil }
            logger.error("link for \(self.machineID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
