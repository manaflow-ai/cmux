import AppKit
import CmuxNextCompat
import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDevices
import CmuxNextSettings
import CryptoKit
import Darwin
import Foundation
import os

private let remoteLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// cmux Remote from the app (docs/cmux-remote.md): the daemon supervises the one signed host
/// that holds Accessibility and Screen Recording; this app tells the daemon which features are
/// on, opens Computer Use channels through the host, signs its own device hub requests with the
/// Screen Sharing worker's device keys (this Mac is one device), reads hub pushes from the
/// worker's one User DO socket, and anchors the worker's device-key renewal while signed in.
@MainActor
final class CmuxRemoteService {
    /// The app's one service (made by ``AppServices/startCmuxRemote(_:)`` when the build embeds
    /// cmux Remote); nil in a build without it.
    static var shared: CmuxRemoteService?
    private weak var daemon: DaemonService?
    /// The app socket's credentials, until the host restarts (a refusal asks again).
    private var grant: RemoteHostAppRequest.Response?
    /// Whether the daemon runs cmux Remote (`remote-host-v1` and an embedded bundle).
    private(set) var available = false
    private var lastConfig: (computerUse: Bool, screenSharing: Bool, headless: Bool)?
    private var anchorTask: Task<Void, Never>?
    /// The person's switches now (the App sets it): Computer Use on with cmux Remote, signed in, headless.
    var currentConfig: (@MainActor () -> (computerUse: Bool, screenSharing: Bool, headless: Bool))?

    init(daemon: DaemonService) {
        self.daemon = daemon
    }

    // MARK: Daemon

    private var connection: DaemonConnection? {
        guard let daemon, daemon.supports(DaemonCapability.remoteHost.rawValue) else { return nil }
        return daemon.connection
    }

    /// The person's switches to the daemon (it saves them and starts or stops the host).
    func apply(computerUse: Bool, screenSharing: Bool, headless: Bool) async {
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
            remoteLogger.notice("cmux Remote config refused: \(AppProviderCredentials.code(of: error), privacy: .public)")
            available = false
        }
    }

    /// Applies the current switches once when none were sent yet; whether the daemon runs cmux Remote.
    func waitAvailable() async -> Bool {
        if lastConfig == nil, let config = currentConfig?() {
            await apply(computerUse: config.computerUse, screenSharing: config.screenSharing, headless: config.headless)
        }
        return available
    }

    /// One host request over the daemon (status, refresh, request, restart, screen.*).
    func call(_ method: String, _ params: CmuxNextDaemon.JSONValue = .object([:])) async throws -> CmuxNextDaemon.JSONValue {
        guard let connection else { throw CmuxRemoteError.unavailable }
        return try await connection.request(RemoteHostCallRequest(method: method, params: params), timeout: .seconds(25))
    }

    func status() async throws -> CmuxNextDaemon.JSONValue {
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
    func openChannel(_ channel: String, extra: [String: String] = [:]) async throws -> (socket: Int32, pid: pid_t, grant: RemoteHostAppRequest.Response) {
        let first = try await appGrant()
        do {
            let opened = try await Self.open(channel, grant: first, extra: extra)
            return (opened.socket, opened.pid, first)
        } catch CmuxRemoteError.refused, CmuxRemoteError.notTheHost {
            let fresh = try await appGrant(refresh: true)
            let opened = try await Self.open(channel, grant: fresh, extra: extra)
            return (opened.socket, opened.pid, fresh)
        }
    }

    // MARK: Hub anchoring

    /// While signed in: anchor the worker's device-key renewal now and every hour, and tell the
    /// worker the account and hub it serves. Stops on sign-out.
    func followHub(_ hub: DeviceHub?, userID: String?, hubURL: URL?, devices: CmuxRemoteDevices) {
        anchorTask?.cancel()
        anchorTask = nil
        guard let hub, let userID, !userID.isEmpty, let hubURL else {
            Task { await devices.signedOut() }
            return
        }
        // task-owner: anchorTask: cancelled by the next followHub (sign-out, another account or hub).
        anchorTask = Task {
            while !Task.isCancelled {
                do {
                    _ = try await hub.client.anchorDevice()
                    await devices.anchored(userID: userID, hubURL: hubURL)
                } catch {
                    remoteLogger.notice("cmux Remote anchor failed: \(String(describing: error), privacy: .public)")
                }
                // wakeup-allow: the anchor's hourly refresh (PROTOCOL.md, Device renewal); one per hour.
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

enum CmuxRemoteError: Error, CustomStringConvertible {
    case unavailable
    case notTheHost
    case refused(String)

    var description: String {
        switch self {
        case .unavailable: "this cmux has no cmux Remote (the daemon does not run it)"
        case .notTheHost: "the app socket's peer is not cmux Remote"
        case let .refused(message): message
        }
    }
}

/// Computer Use through cmux Remote: the host starts a worker for each channel.
nonisolated struct CmuxRemoteComputerUse: ComputerUseRemoteSpawning {
    let open: @Sendable () async throws -> ComputerUseRemoteChannel

    func openComputerUse() async throws -> ComputerUseRemoteChannel { try await open() }

    /// cmux Remote's executable, from the embedded bundle (the worker runs it).
    static func executable(bundle: Bundle = .main) -> URL? {
        for name in ["cmux Remote.app", "cmux Remote (dev).app"] {
            let url = bundle.bundleURL.appending(path: "Contents/Library/\(name)/Contents/MacOS/cmux-remote")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
