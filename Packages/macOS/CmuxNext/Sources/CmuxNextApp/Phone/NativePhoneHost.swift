import CmuxNativeHost
import CmuxNativeLink
import CmuxNativeWire
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Observation
import os

/// The native cmux iPhone app's host on this Mac (native-mobile/ARCHITECTURE.md): the Mac app is
/// the host. Once the person turns it on (Settings > iPhone), the Mac registers with the signaling
/// Worker (host id and secret in the Keychain, `NativePhoneHostCredentials`), then runs
/// `NativeHostService` against this app's own cmux-tui daemon: phones' `daemon:<uuid>` channels
/// open the socket the app is connected to now, so a daemon restart is followed without dropping
/// the phones' links. It stops on quit and when turned off. The `cmux-native-host` CLI runs the
/// same service without the app.
@MainActor
@Observable
final class NativePhoneHost {
    enum Phase: Equatable {
        case off
        case registering
        case connecting
        case listening
        case reconnecting(String)
        case failed(String)
    }

    /// A connected phone.
    struct Peer: Equatable, Identifiable {
        let id: String
        let userID: String?
        let path: LinkPath
    }

    /// The pairing code on screen (`XXXX-XXXX`, single use, 10 minutes).
    struct Pairing: Equatable {
        let code: String
        let expiresAt: Date

        /// What the QR code holds: the iPhone app opens it and pairs with `code`.
        var url: String { "cmux-native://pair?code=\(code)" }
    }

    static let enabledKey = "cmux.phone.nativeHost.enabled"
    static let defaultAPI = URL(string: "https://cmux-next-native.debussy.workers.dev")!

    private(set) var enabled: Bool
    private(set) var phase: Phase = .off
    private(set) var hostID: String?
    private(set) var hostName: String?
    private(set) var peers: [Peer] = []
    private(set) var pairing: Pairing?
    private(set) var pairingBusy = false
    /// The last pairing or registration failure, shown until the next attempt.
    private(set) var lastError: String?
    /// Whether the app's daemon socket is known (phones' terminals need it).
    private(set) var hasDaemon = false

    @ObservationIgnored private let daemon: DaemonService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: NativePhoneHostCredentials
    @ObservationIgnored private let apiBase: URL
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.phone")
    @ObservationIgnored private let socket = DaemonSocketBox()
    @ObservationIgnored private var config: HostConfig?
    @ObservationIgnored private var service: NativeHostService?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var daemonWatch: Task<Void, Never>?
    /// Bumped by every activation and deactivation; late events of an older run drop out.
    @ObservationIgnored private var generation = 0

    init(daemon: DaemonService, defaults: UserDefaults, credentials: NativePhoneHostCredentials, apiBase: URL) {
        self.daemon = daemon
        self.defaults = defaults
        self.credentials = credentials
        self.apiBase = apiBase
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// The app's host: the standard defaults, the Keychain under the bundle id, and the Worker
    /// (`CMUX_NATIVE_API` overrides it for a test Worker).
    static func app(daemon: DaemonService, bundleID: String?,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> NativePhoneHost {
        let api = environment["CMUX_NATIVE_API"].flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? defaultAPI
        return NativePhoneHost(daemon: daemon, defaults: .standard,
                               credentials: NativePhoneHostCredentials(service: NativePhoneHostCredentials.service(bundleID: bundleID)),
                               apiBase: api)
    }

    // MARK: Lifecycle

    /// Follows the app's daemon from launch, and runs the host when it was left on.
    func start() {
        guard daemonWatch == nil else { return }
        let daemon = daemon
        daemonWatch = Task { [weak self] in
            for await identity in ObservationStream({ daemon.identity }) {
                var path: String?
                if identity != nil { path = try? await daemon.endpoint().socketPath }
                guard let self, !Task.isCancelled else { return }
                self.socket.set(path)
                self.hasDaemon = path != nil
                self.logger.info("phone host daemon socket: \(path ?? "none", privacy: .public)")
            }
        }
        if enabled { activate() }
    }

    /// Quit: the host and its phones' links end.
    func stop() {
        daemonWatch?.cancel()
        daemonWatch = nil
        deactivate()
    }

    /// The Settings toggle. Off ends every phone's link; the registration stays for next time.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { activate() } else { deactivate() }
    }

    /// Shows a fresh pairing code (the older one stops working).
    func pair() async {
        guard enabled, let config else { return }
        pairingBusy = true
        lastError = nil
        defer { pairingBusy = false }
        do {
            let response = try await WorkerAPI(baseURL: config.api, token: config.hostSecret).pairingCode()
            guard self.config == config else { return }
            pairing = Pairing(code: response.pairingCode, expiresAt: Date(timeIntervalSince1970: response.expiresAt / 1000))
        } catch {
            logger.error("pairing code failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
        }
    }

    func endPairing() {
        pairing = nil
    }

    /// Forgets this Mac's registration (the Keychain item); a running host registers again.
    /// Phones paired with the old registration must pair again.
    func resetRegistration() {
        let wasOn = enabled
        deactivate()
        do { try credentials.delete() } catch { lastError = String(describing: error) }
        hostID = nil
        hostName = nil
        if wasOn { activate() }
    }

    // MARK: Running

    private func activate() {
        deactivate()
        generation += 1
        let current = generation
        lastError = nil
        phase = .connecting
        running = Task { [weak self] in
            guard let self else { return }
            do {
                let config = try await self.registration(generation: current)
                guard self.generation == current, !Task.isCancelled else { return }
                self.run(config, generation: current)
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.logger.error("phone host registration failed: \(String(describing: error), privacy: .public)")
                self.phase = .failed(String(describing: error))
            }
        }
    }

    private func deactivate() {
        generation += 1
        running?.cancel()
        running = nil
        let service = service
        self.service = nil
        config = nil
        phase = .off
        peers = []
        pairing = nil
        pairingBusy = false
        // task-owner: teardown hop; NativeHostService.stop() is idempotent
        if let service { Task { await service.stop() } }
    }

    /// The saved registration for this Worker, else a new one (whose first pairing code shows).
    private func registration(generation current: Int) async throws -> HostConfig {
        if let saved = try credentials.load(), saved.api == apiBase {
            hostID = saved.hostID
            hostName = saved.name
            return saved
        }
        phase = .registering
        let name = await MacName.computerName()
        let response = try await WorkerAPI(baseURL: apiBase).registerHost(name: name, platform: "macos")
        let config = HostConfig(api: apiBase, hostID: response.hostID, hostSecret: response.hostSecret, name: name)
        try credentials.save(config)
        hostID = config.hostID
        hostName = name
        if generation == current, let expires = response.pairingExpiresAt {
            pairing = Pairing(code: response.pairingCode, expiresAt: Date(timeIntervalSince1970: expires / 1000))
        }
        logger.info("phone host registered \(config.hostID, privacy: .public)")
        return config
    }

    private func run(_ config: HostConfig, generation current: Int) {
        self.config = config
        let (events, sink) = AsyncStream<NativeHostEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let socket = socket
        let logger = logger
        let acceptor = WebRTCHostAcceptor(configuration: .init(apiBase: config.api, hostID: config.hostID, hostSecret: config.hostSecret))
        let service = NativeHostService(acceptor: acceptor, configuration: .init(
            locator: DaemonSocketLocator(provider: { socket.get() }),
            log: { line in logger.debug("\(line, privacy: .public)") },
            onEvent: { sink.yield($0) }))
        self.service = service
        running = Task { [weak self] in
            await service.start()
            for await event in events {
                guard let self, self.generation == current else { break }
                self.apply(event)
            }
            sink.finish()
        }
    }

    private func apply(_ event: NativeHostEvent) {
        switch event {
        case .acceptor(let state):
            switch state {
            case .stopped: break
            case .connecting: phase = .connecting
            case .listening: phase = .listening
            case .reconnecting(let reason): phase = .reconnecting(reason)
            case .failed(let reason): phase = .failed(reason)
            }
        case .peerConnected(let peer, let info):
            peers.removeAll { $0.id == peer.sid }
            peers.append(Peer(id: peer.sid, userID: peer.userID, path: info?.path ?? .unknown))
        case .peerDisconnected(let peer):
            peers.removeAll { $0.id == peer.sid }
        }
    }
}

/// The daemon socket the host's daemon channels open: written on the main actor, read from the
/// bridge's own tasks (the same carve-out as `PolicyBlock`).
nonisolated final class DaemonSocketBox: Sendable {
    private let path = Mutex<String?>(nil)

    func get() -> String? { path.withLock { $0 } }
    func set(_ value: String?) { path.withLock { $0 = value } }
}
