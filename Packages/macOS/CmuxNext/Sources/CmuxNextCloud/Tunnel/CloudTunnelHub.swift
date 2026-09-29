public import Foundation
import os

/// The app's one userspace WireGuard tunnel: `cmux-tui wg hub`, which serves
/// SOCKS5 on a Unix socket to every machine link (a WireGuard key supports
/// one live session, so links share it). Enrolls this Mac's public key with
/// `POST /api/vm/tunnel` each time the hub starts, so a rotated or revoked
/// peer heals on the next start. Concurrent callers share one start.
public actor CloudTunnelHub {
    private let api: CloudAPIClient
    private let paths: CloudPaths
    private let binary: URL
    private let deviceName: String
    private var child: ChildProcess?
    private var socket: String?
    private var starting: Task<String, any Error>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.hub")

    public init(api: CloudAPIClient, paths: CloudPaths, binary: URL, deviceName: String) {
        self.api = api
        self.paths = paths
        self.binary = binary
        self.deviceName = deviceName
    }

    /// The hub's SOCKS socket, starting the hub when it is not running.
    public func socketPath() async throws -> String {
        if let socket, child?.isRunning == true { return socket }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Stops the hub (sign-out, quit). Links using it fail and reconnect.
    public func stop() {
        child?.terminate()
        child = nil
        socket = nil
    }

    /// Revokes this Mac's WireGuard peer on the server (sign-out).
    public func revoke() async {
        stop()
        guard let id = try? paths.loadOrCreateDeviceID() else { return }
        do { try await api.revokeTunnel(deviceID: id) } catch { logger.error("tunnel revoke failed: \(String(describing: error), privacy: .public)") }
    }

    private func start() async throws -> String {
        stop()
        try paths.prepare()
        let key = try paths.loadOrCreateKey()
        let request = CloudTunnelEnrollment.Request(
            clientPublicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            deviceID: try paths.loadOrCreateDeviceID(),
            deviceName: deviceName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: "arm64",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "next"
        )
        let enrollment = try await api.enrollTunnel(request)
        try paths.writeSecret(WireGuardConfig.completed(enrollment, privateKey: key.rawRepresentation.base64EncodedString()),
                              to: paths.wireGuardConfig)
        let socketPath = paths.hubSocket
        unlink(socketPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: [
            "wg", "hub", "--config", paths.wireGuardConfig.path, "--socket", socketPath, "--exit-with-parent",
        ])
        try child.start()
        self.child = child
        let ready = try await child.firstLine(within: .seconds(45), label: "cmux-tui wg hub") { line in
            if case .hubReady(let socket) = CloudLinkEvent.parse(line) { return socket }
            return nil
        }
        socket = ready
        logger.info("wireguard hub ready (tunnel \(enrollment.tunnelId, privacy: .public))")
        return ready
    }
}
