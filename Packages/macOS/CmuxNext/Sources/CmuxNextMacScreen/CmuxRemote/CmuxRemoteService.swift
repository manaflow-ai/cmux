import CmuxNextCompat
public import CmuxNextComputerUse
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextDevices
import CmuxNextWakeups
import Darwin
public import Foundation
import os

private let remoteLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// cmux Remote from the app (docs/cmux-remote.md): the daemon supervises the one signed host
/// that holds Accessibility and Screen Recording; this app tells the daemon which features are
/// on, opens Computer Use channels through the host, signs its own device hub requests with the
/// Screen Sharing worker's device keys (this Mac is one device), reads hub pushes from the
/// worker's one User DO socket, and anchors the worker's device-key renewal while signed in.
@MainActor
public final class CmuxRemoteService {
    /// This build embeds cmux Remote (``start(_:)`` ran).
    public private(set) var started = false
    /// This app's local daemon connection when it serves `remote-host-v1`, else nil.
    private let connectionSource: @MainActor () -> DaemonConnection?
    /// The app socket's credentials, until the host restarts (a refusal asks again).
    private var grant: RemoteHostAppRequest.Response?
    /// Whether the daemon runs cmux Remote (`remote-host-v1` and an embedded bundle).
    public private(set) var available = false
    private var lastConfig: (computerUse: Bool, screenSharing: Bool, headless: Bool)?
    /// The anchor's hourly refresh (PROTOCOL.md, Device renewal).
    private let anchorTimer = DemandTimer(owner: "cmux-remote.anchor")
    /// The person's switches now (the App sets it): Computer Use on with cmux Remote, signed in, headless.
    public var currentConfig: (@MainActor () -> (computerUse: Bool, screenSharing: Bool, headless: Bool))?

    public init(connection: @escaping @MainActor () -> DaemonConnection?) {
        connectionSource = connection
    }

    /// This app's local daemon: its connection while it serves `remote-host-v1`.
    public convenience init(daemon: DaemonService) {
        self.init { [weak daemon] in daemon?.supports(DaemonCapability.remoteHost.rawValue) == true ? daemon?.connection : nil }
    }

    func markStarted() { started = true }

    // MARK: Daemon

    private var connection: DaemonConnection? { connectionSource() }

    /// The person's switches to the daemon (it saves them and starts or stops the host).
    public func apply(computerUse: Bool, screenSharing: Bool, headless: Bool) async {
        let next = (computerUse, screenSharing, headless)
        if let lastConfig, lastConfig == next { return }
        guard let connection else {
            available = false
            return
        }
        do {
            _ = try await connection.request(RemoteHostConfigRequest(computerUse: computerUse, screenSharing: screenSharing,
                                                                     headless: headless))
            lastConfig = next
            available = true
        } catch {
            remoteLogger.notice("cmux Remote config refused: \(String(describing: error), privacy: .public)")
            available = false
        }
    }

    /// Applies the current switches once when none were sent yet; whether the daemon runs cmux Remote.
    public func waitAvailable() async -> Bool {
        if lastConfig == nil, let config = currentConfig?() {
            await apply(computerUse: config.computerUse, screenSharing: config.screenSharing, headless: config.headless)
        }
        return available
    }

    /// One host request over the daemon (status, refresh, request, restart, screen.*).
    public func call(_ method: String, _ params: CmuxNextDaemon.JSONValue = .object([:])) async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(RemoteHostCallRequest(method: method, params: params), timeout: .seconds(25))
    }

    public func status() async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(RemoteHostStatusRequest())
    }

    // MARK: App socket

    /// A channel to cmux Remote: hello with this launch's grant, then `channel`. The returned
    /// descriptor is past the host's answer; the result names the process behind it.
    nonisolated static func open(_ channel: String, grant: RemoteHostAppRequest.Response,
                                 extra: [String: String] = [:]) async throws -> (socket: Int32, pid: pid_t) {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = try RemoteSocket.connect(grant.socket)
            guard RemoteSocket.peerPID(descriptor) == grant.hostPID else {
                close(descriptor)
                throw CmuxRemoteError.notTheHost
            }
            var open: [String: String] = ["channel": channel]
            for (key, value) in extra { open[key] = value }
            let hello = try JSONSerialization.data(withJSONObject: ["type": "hello", "secret": grant.secret]) + Data([0x0A])
            let request = try JSONSerialization.data(withJSONObject: ["id": 1].merging(open) { $1 } as [String: Any]) + Data([0x0A])
            guard RemoteSocket.writeAll(descriptor, hello + request), let line = RemoteSocket.readLine(descriptor),
                  let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                close(descriptor)
                throw CmuxRemoteError.refused("cmux Remote closed the channel")
            }
            guard answer["ok"] as? Bool == true else {
                close(descriptor)
                let message = (answer["error"] as? [String: Any])?["message"] as? String ?? "refused"
                throw CmuxRemoteError.refused(message)
            }
            let pid = ((answer["result"] as? [String: Any])?["pid"] as? Int).map { pid_t($0) } ?? pid_t(grant.hostPID)
            return (descriptor, pid)
        }.value
    }

    /// This launch's app grant, asked again after the host refused it (a restarted host).
    func appGrant(refresh: Bool = false) async throws -> RemoteHostAppRequest.Response {
        if let grant, !refresh { return grant }
        guard let connection else { throw CmuxRemoteError.unavailable }
        let fresh = try await connection.request(RemoteHostAppRequest(), timeout: .seconds(25))
        grant = fresh
        return fresh
    }

    /// Opens `channel`, asking for a fresh grant once when the host refuses this one.
    public func openChannel(_ channel: String, extra: [String: String] = [:]) async throws -> (socket: Int32, pid: pid_t, grant: RemoteHostAppRequest.Response) {
        var grant = try await appGrant()
        let opened: (socket: Int32, pid: pid_t)
        do {
            opened = try await Self.open(channel, grant: grant, extra: extra)
        } catch CmuxRemoteError.refused, CmuxRemoteError.notTheHost {
            grant = try await appGrant(refresh: true)
            opened = try await Self.open(channel, grant: grant, extra: extra)
        }
        let result = (socket: opened.socket, pid: opened.pid, grant: grant)
        return result
    }

    // MARK: Hub anchoring

    /// While signed in: anchor the worker's device-key renewal now and every hour, and tell the
    /// worker the account and hub it serves. Stops on sign-out.
    public func followHub(_ hub: DeviceHub?, userID: String?, hubURL: URL?, devices: CmuxRemoteDevices) {
        anchorTimer.cancel()
        guard let hub, let userID, !userID.isEmpty, let hubURL else {
            // task-owner: one sign-out line to the worker; nothing waits on it.
            Task { await devices.signedOut() }
            return
        }
        anchor(hub, userID: userID, hubURL: hubURL, devices: devices)
    }

    /// One anchor now, and the next in an hour (the timer is cancelled by the next followHub).
    private func anchor(_ hub: DeviceHub, userID: String, hubURL: URL, devices: CmuxRemoteDevices) {
        // task-owner: one anchor write; the next one is the timer's.
        Task {
            do {
                _ = try await hub.client.anchorDevice()
                await devices.anchored(userID: userID, hubURL: hubURL)
            } catch {
                remoteLogger.notice("cmux Remote anchor failed: \(String(describing: error), privacy: .public)")
            }
        }
        anchorTimer.schedule(after: .seconds(3600)) { @MainActor [weak self] in
            self?.anchor(hub, userID: userID, hubURL: hubURL, devices: devices)
        }
    }
}
