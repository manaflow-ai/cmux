import CmuxNextCompat
public import Foundation
import os

/// The app's one userspace WireGuard tunnel: `cmux-tui wg hub`, which serves
/// SOCKS5 on a Unix socket to every machine link (a WireGuard key supports
/// one live session, so links share it). Enrolls this Mac's public key with
/// `POST /api/vm/tunnel` each time the hub starts, so a rotated or revoked
/// peer heals on the next start. Concurrent callers share one start.
///
/// Lifecycle (`Phase`): idle -> starting -> running, back to idle on
/// `stop()`; `revoke()` (sign-out) moves to `revoked`, which refuses every
/// start until `resume()` (sign-in). Every start carries the generation it
/// began in and abandons itself after any `await` once `stop`/`revoke`
/// bumped it, and `revoke()` waits for an in-flight start before it sends
/// the server revoke, so an enrollment can never land after the revoke.
public actor CloudTunnelHub {
    public enum HubError: Error, Sendable, Equatable {
        /// Signed out: no enrollment until the next sign-in.
        case revoked
    }

    private enum Phase {
        case idle
        case starting(Task<String, any Error>)
        case running(socket: String)
        case revoked
    }

    private let api: CloudAPIClient
    private let paths: CloudPaths
    private let binary: URL
    private let deviceName: String
    private var phase: Phase = .idle
    /// Bumped by `stop()` and `revoke()`; a start from an older one abandons.
    private var generation: UInt64 = 0
    private var child: ChildProcess?
    /// When the hub restarted itself after its process ended (ssh routes, below); at most
    /// ``maxRestarts`` in ``restartWindow``.
    private var restarts: [ContinuousClock.Instant] = []
    static let maxRestarts = 3
    static let restartWindow: Duration = .seconds(600)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.hub")

    public init(api: CloudAPIClient, paths: CloudPaths, binary: URL, deviceName: String) {
        self.api = api
        self.paths = paths
        self.binary = binary
        self.deviceName = deviceName
    }

    /// The hub's SOCKS socket, starting the hub when it is not running.
    public func socketPath() async throws -> String {
        switch phase {
        case .revoked:
            throw HubError.revoked
        case .running(let socket) where child?.isRunning == true:
            return socket
        case .starting(let task):
            return try await task.value
        case .idle, .running:
            let generation = generation
            let task = Task { try await self.start(generation: generation) }
            phase = .starting(task)
            do {
                return try await task.value
            } catch {
                if case .starting(let current) = phase, current == task { phase = .idle }
                throw error
            }
        }
    }

    /// Stops the hub (quit). Links using it fail and reconnect.
    public func stop() {
        generation += 1
        terminateChild()
        if case .revoked = phase { return }
        phase = .idle
    }

    /// Revokes this Mac's WireGuard peer on the server (sign-out) and
    /// refuses new starts until `resume()`.
    public func revoke() async {
        generation += 1
        let inflight: Task<String, any Error>? = if case .starting(let task) = phase { task } else { nil }
        phase = .revoked
        terminateChild()
        // Its enrollment may already be on the wire; let it land (the start
        // then abandons itself) so the revoke below is the server's last word.
        _ = await inflight?.result
        guard let id = try? paths.loadOrCreateDeviceID() else { return }
        do { try await api.revokeTunnel(deviceID: id) } catch { logger.error("tunnel revoke failed: \(String(describing: error), privacy: .public)") }
    }

    /// Allows enrollment again after a sign-in.
    public func resume() {
        if case .revoked = phase { phase = .idle }
    }

    /// Moves ``CloudPaths/hubLink`` to the running hub's socket (a new link, then a rename over
    /// the old one, so a dialer never sees it missing). A failure fails the start: an ssh route
    /// through a stale link would look enrolled and never connect.
    private func pointHubLink(at socket: String) throws {
        let link = paths.hubLink, staged = link + ".new"
        try? FileManager.checked.removeItem(atPath: staged)
        try FileManager.checked.createSymbolicLink(atPath: staged, withDestinationPath: socket)
        guard rename(staged, link) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// The hub's socket through ``CloudPaths/hubLink``, starting the hub when it is not running,
    /// and re-pointing the link when something moved it.
    public func linkedSocketPath() async throws -> String {
        let socket = try await socketPath()
        if (try? FileManager.checked.destinationOfSymbolicLink(atPath: paths.hubLink)) != socket { try pointHubLink(at: socket) }
        return paths.hubLink
    }

    /// When the hub's process ends by itself (not `stop()` or `revoke()`, which bump the
    /// generation) and an ssh route depends on it, the hub starts again, at most ``maxRestarts``
    /// times in ``restartWindow``. Stop condition: the process ended under another generation, or
    /// the budget is spent; the task ends with the process.
    private func watch(_ child: ChildProcess, generation: UInt64) {
        // task-owner: ends when the hub process ends; restarts only under the same generation.
        Task { [weak self] in
            _ = await child.waitForExit()
            await self?.ended(child, generation: generation)
        }
    }

    private func ended(_ ended: ChildProcess, generation: UInt64) async {
        guard generation == self.generation, child === ended else { return }
        child = nil
        // A caller already saw the process gone and began a start: that start is the restart.
        if case .starting = phase { return }
        phase = .idle
        let now = ContinuousClock.now
        restarts.removeAll { $0.duration(to: now) > Self.restartWindow }
        guard paths.hasSSHRoutes(), restarts.count < Self.maxRestarts else { return }
        restarts.append(now)
        do { _ = try await socketPath() } catch { logger.error("wireguard hub restart: \(String(describing: error), privacy: .public)") }
    }

    private func terminateChild() {
        child?.terminate()
        child = nil
    }

    private func start(generation: UInt64) async throws -> String {
        terminateChild()
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
        guard generation == self.generation else { throw CancellationError() }
        try paths.writeSecret(WireGuardConfig.shared.completed(enrollment, privateKey: key.rawRepresentation.base64EncodedString()),
                              to: paths.wireGuardConfig)
        let socketPath = paths.hubSocket
        unlink(socketPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ChildProcessError.missingBinary(binary.path) }
        let child = ChildProcess(executable: binary, arguments: [
            "wg", "hub", "--config", paths.wireGuardConfig.path, "--socket", socketPath, "--exit-with-parent",
        ])
        try child.start()
        self.child = child
        let ready: String
        do {
            ready = try await child.firstLine(within: .seconds(45), label: "cmux-tui wg hub") { line in
                if case .hubReady(let socket) = CloudLinkEvent.parse(line) { return socket }
                return nil
            }
        } catch {
            child.terminate()
            if self.child === child { self.child = nil }
            throw error
        }
        guard generation == self.generation else {
            child.terminate()
            if self.child === child { self.child = nil }
            throw CancellationError()
        }
        do {
            try pointHubLink(at: ready)
        } catch {
            child.terminate()
            if self.child === child { self.child = nil }
            throw error
        }
        phase = .running(socket: ready)
        watch(child, generation: generation)
        logger.info("wireguard hub ready (tunnel \(enrollment.tunnelId, privacy: .public))")
        return ready
    }
}
