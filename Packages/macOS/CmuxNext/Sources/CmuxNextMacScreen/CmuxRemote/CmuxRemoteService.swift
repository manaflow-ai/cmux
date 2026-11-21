import ApplicationServices
import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextDevices
import CmuxNextWakeups
import CoreGraphics
import Darwin
public import Foundation
import os

private let remoteLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// cmux Remote from the app (docs/cmux-remote.md): the daemon supervises the one signed host
/// that holds Accessibility and Screen Recording; this app tells the daemon which features are
/// on, sends the Computer Use policy (its worker serves agents itself, through the daemon), signs its own device hub requests with the
/// Screen Sharing worker's device keys (this Mac is one device), reads hub pushes from the
/// worker's one User DO socket, and anchors the worker's device-key renewal while signed in.
@MainActor
public final class CmuxRemoteService {
    /// This build embeds cmux Remote (``start(_:)`` ran).
    public private(set) var started = false
    /// cmux Remote's Computer Use worker as the last host status said (Computer Use Setup follows it).
    public let computerUse = CmuxRemoteComputerUseState()
    /// This app's local daemon connection when it serves `remote-host-v1`, else nil.
    private let connectionSource: @MainActor () -> DaemonConnection?
    /// The app socket's credentials, until the host restarts (a refusal asks again).
    private var grant: RemoteHostAppRequest.Response?
    /// Whether the daemon runs cmux Remote (`remote-host-v1` and an embedded bundle).
    public private(set) var available = false
    /// The hub made with cmux Remote's device identity, while it is the one running.
    var remoteHub: DeviceHub?
    private var lastConfig: (computerUse: Bool, screenSharing: Bool, headless: Bool)?
    /// The anchor's hourly refresh (PROTOCOL.md, Device renewal).
    private let anchorTimer = DemandTimer(owner: "cmux-remote.anchor")
    /// The person's switches now (``follow`` sets it once the settings load): Computer Use on with
    /// cmux Remote, signed in, headless. Callers before that wait for it (``waitAvailable()``).
    public var currentConfig: (@MainActor () -> (computerUse: Bool, screenSharing: Bool, headless: Bool))? {
        didSet {
            guard currentConfig != nil else { return }
            let waiting = configWaiters
            configWaiters = [:]
            for waiter in waiting.values { waiter.resume() }
        }
    }
    private var configWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private let configClock: any Clock<Duration>
    /// ``followAppPermissions(activation:)`` ran (once, at launch).
    private var followsAppPermissions = false

    public init(clock: any Clock<Duration> = ContinuousClock(), connection: @escaping @MainActor () -> DaemonConnection?) {
        configClock = clock
        connectionSource = connection
    }

    /// This app's local daemon: its connection while it serves `remote-host-v1`.
    public convenience init(daemon: DaemonService) {
        self.init { [weak daemon] in daemon?.supports(DaemonCapability.remoteHost.rawValue) == true ? daemon?.connection : nil }
    }

    func markStarted() {
        started = true
        computerUse.embedded = true
    }

    // MARK: Daemon

    private var connection: DaemonConnection? { connectionSource() }

    /// The daemon connection now (a reconnect or a new daemon is a new object), nil without one.
    var currentConnectionObject: AnyObject? { connection }

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
        (try? await configuredAvailability()) ?? false
    }

    /// Hub startup must distinguish an absent worker from settings that never arrived.
    func configuredAvailability() async throws -> Bool {
        try Task.checkCancellation()
        if currentConfig == nil {
            let id = UUID()
            // Platform continuation lifetime only; use the shared one-shot deadline adapter.
            let timer = DemandTimer(owner: "cmux-remote.configuration", clock: configClock)
            defer { timer.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled else { waiter.resume(throwing: CancellationError()); return }
                    configWaiters[id] = waiter
                    timer.schedule(after: .seconds(30)) { @MainActor [weak self] in
                        self?.configWaiters.removeValue(forKey: id)?.resume(throwing: CmuxRemoteError.configurationTimeout)
                    }
                }
            } onCancel: {
                // Cancellation may arrive on any executor; remove only this caller's waiter.
                MainDelivery().run { [weak self] in
                    self?.configWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }
        try Task.checkCancellation()
        guard let config = currentConfig?() else { return false }
        if lastConfig == nil {
            await apply(computerUse: config.computerUse, screenSharing: config.screenSharing, headless: config.headless)
        }
        // Both switches off (Computer Use off, and signed out): nothing runs in cmux Remote.
        return available && (config.computerUse || config.screenSharing)
    }

    /// The worker as Stop Sharing This Mac sees it (``MacScreenActions``): running once started, and its
    /// `screen.stop_session` ends the session it hosts.
    public var screenSessionWorker: MacScreenWorkerSession {
        MacScreenWorkerSession(running: { [weak self] in self?.started == true },
                               stop: { [weak self] in
                                   guard let self else { throw CmuxRemoteError.unavailable }
                                   _ = try await self.call("screen.stop_session")
                               })
    }

    /// One host request over the daemon (status, refresh, request, restart, screen.*).
    public func call(_ method: String, _ params: CmuxNextDaemon.JSONValue = .object([:]),
                     timeout: Duration = .seconds(25)) async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(RemoteHostCallRequest(method: method, params: params), timeout: timeout)
    }

    /// One daemon request on this app's own (verified) connection.
    func daemonRequest<Request: DaemonRequest>(_ request: Request) async throws -> Request.Response {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(request, timeout: .seconds(25))
    }

    public func status() async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(RemoteHostStatusRequest())
    }

    // MARK: The app's own grants

    /// This app's own Screen Recording and Accessibility now (read only, never a prompt).
    static func appPermissions() -> RemoteHostConfigRequest.AppPermissions {
        RemoteHostConfigRequest.AppPermissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }

    /// Tells the daemon this app's own grants (`remote-host-config` `app_permissions` only, no
    /// switch: nothing saved, started or stopped). Where no cmux Remote is bundled (Release and
    /// NIGHTLY) the app captures the screen itself, so `cmux remote-host grants` reads these.
    public func reportAppPermissions() async {
        guard let connection else { return }
        do {
            _ = try await connection.request(RemoteHostConfigRequest(appPermissions: Self.appPermissions()))
        } catch {
            remoteLogger.notice("cmux Remote app grants not reported: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reports this app's grants at each daemon connection that serves `remote-host-v1` and
    /// whenever the app becomes active, since the person may have just turned one on in System
    /// Settings. Runs in every build, with or without cmux Remote bundled. Activation comes
    /// from `activation`'s existing app-active observer (no observer of its own).
    func followAppPermissions(activation: MacScreenSystemShortcuts) {
        guard !followsAppPermissions else { return }
        followsAppPermissions = true
        activation.onAppActive = { [weak self] in
            // task-owner: one report per activation, bounded by the daemon request timeout.
            Task { [weak self] in await self?.reportAppPermissions() }
        }
        // The source reads the daemon's connection and capabilities, so a new connection wakes this.
        let connected = { @MainActor [weak self] in self?.connection.map { ObjectIdentifier($0) } }
        // task-owner: lives with the app; one report per daemon connection.
        Task { [weak self] in
            for await current in ObservationStream(connected) where current != nil {
                await self?.reportAppPermissions()
            }
        }
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
            // Only a running cmux Remote hears it: with both switches off nothing opens a channel.
            // task-owner: one sign-out line to the worker; nothing waits on it.
            Task { [weak self] in
                guard await self?.waitAvailable() == true else { return }
                await devices.signedOut()
            }
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
