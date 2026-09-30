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
        guard !stopped else { throw CancellationError() }
        if let socket, child?.isRunning == true, FileManager.default.fileExists(atPath: socket) { return socket }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Ends the link for good (machine removed, sign-out, quit).
    public func stop() {
        stopped = true
        child?.terminate()
        child = nil
        socket = nil
    }

    /// PID of the running link process, for diagnostics.
    public var pid: Int32? { child?.pid }

    private func start() async throws -> String {
        child?.terminate()
        child = nil
        socket = nil
        // `stop()` can run during every await; never start the hub or spawn
        // a link for a machine that was removed or signed out meanwhile.
        let endpoint = try await api.attachEndpoint(machineID)
        guard !stopped else { throw CancellationError() }
        let hubSocket = try await hub.socketPath()
        guard !stopped else { throw CancellationError() }
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
            guard !stopped else {
                child.terminate()
                if self.child === child { self.child = nil }
                throw CancellationError()
            }
            socket = path
            logger.info("link up for \(self.machineID, privacy: .public) pid \(child.pid ?? 0)")
            return path
        } catch {
            child.terminate()
            self.child = nil
            logger.error("link for \(self.machineID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
