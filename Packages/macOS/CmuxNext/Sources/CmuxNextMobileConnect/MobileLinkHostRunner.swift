import CmuxControlPlane
import CmuxLinkDirect
import CmuxLinkSignaling
import CmuxLinkWebRTC
import CmuxLinkWG
import CmuxMobileConnect
import CmuxMobileConnectHost
import CmuxMobileHost
import CmuxMobileWire
import CmuxNextMobileLink
public import CmuxNextDaemon
import CmuxNextWakeups
import CmuxPairing
import Foundation
import os

/// One run of the cmux.mobile/1 phone host for one signed-in account
/// (d1-terminal-ux.md section 2, b5-mac-host.md): `MobileHostAssembly`
/// (B4 direct with Bonjour, B2 WebRTC, B3 behind its DEV switch) over the
/// daemon (`DaemonMobileDaemon`), authorized by the account's `trust:<user>`
/// mirror, registered with `HostDO` through `HostControlUplink`, whose relayed
/// `signal` frames feed the WebRTC acceptors. Single use: `stop()` is final.
public actor MobileLinkHostRunner {
    private let account: any MobileLinkHostAccount
    private let options: MobileLinkHostOptions
    private let endpointProvider: DaemonConnection.EndpointProvider
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.mobile-link")
    private var daemon: DaemonMobileDaemon?
    private var userClient: ControlPlaneClient?
    private var mirror: TrustStoreMirror?
    private var assembly: MobileHostAssembly?
    private let socket = HostSocketBox()
    private var uplinkTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(account: any MobileLinkHostAccount, options: MobileLinkHostOptions,
                endpointProvider: @escaping DaemonConnection.EndpointProvider) {
        self.account = account
        self.options = options
        self.endpointProvider = endpointProvider
    }

    /// Starts serving phones; returns the direct port. The control plane
    /// (trust updates, HostDO presence and signaling) connects in the
    /// background and reconnects with backoff, so a direct phone on the LAN
    /// works even while the API is unreachable.
    public func start() async throws -> UInt16 {
        guard !started, !stopped else { throw CancellationError() }
        started = true
        let principal = try await account.principal()
        let keys = MobileLinkKeyStore(directory: options.keyDirectory)
        let direct = try DirectIdentity(privateKeyRepresentation: keys.privateKey(.direct))
        let wireGuard = options.wireGuardOverWebRTC
            ? try WireGuardPrivateKey(rawRepresentation: keys.privateKey(.wireGuard)) : nil
        let daemon = try await DaemonMobileDaemon.connect(hostID: principal.hostID, endpointProvider: endpointProvider)
        self.daemon = daemon

        let account = account
        let client = ControlPlaneClient(
            configuration: ControlPlaneConfiguration(
                url: Self.socketURL(principal.apiBaseURL, path: "/v1/wire/user"),
                client: HelloClient(install: principal.install, platform: "macos", appVersion: options.appVersion)),
            transport: URLSessionControlPlaneTransport(),
            tokenProvider: { try await account.installToken() })
        await client.start()
        let mirror = TrustStoreMirror()
        await mirror.start(client: client, user: principal.accountUserID)
        userClient = client
        self.mirror = mirror

        let box = socket
        let channel = SignalFrameChannel { frame in try await box.send(try MobileFrame.signal(frame).jsonValue) }
        // TURN credentials ride a `read` on the host socket, which the uplink
        // owns; until it exposes reads, ICE is STUN only (P2P, no relay).
        let signaling = MobileHostSignaling(router: SignalRouter(channel: channel), iceServers: StaticICEServerProvider(.stunOnly),
                                            close: { channel.finish() })
        let assembly = MobileHostAssembly(
            credentials: MobileHostCredentials(hostID: principal.hostID, accountUserID: principal.accountUserID, direct: direct,
                                               webrtc: account.webrtcIdentity, wireGuard: wireGuard),
            trust: MobileHostTrust(mirror: mirror, environment: principal.environment, accountUserID: principal.accountUserID),
            daemon: daemon, signaling: signaling,
            options: MobileHostAssemblyOptions(listen: DirectListenConfiguration(bonjourName: options.macName),
                                               wireGuardOverWebRTC: options.wireGuardOverWebRTC))
        self.assembly = assembly
        let port = try await assembly.start()
        logger.info("phone link: listening on \(port, privacy: .public)")

        uplinkTask = Task { [logger, appVersion = options.appVersion] in
            await Self.runUplink(principal: principal, account: account, host: assembly.host, box: box, channel: channel,
                                 appVersion: appVersion, logger: logger)
        }
        if let signer = account.installSigner {
            publishTask = Task { [logger] in
                await Self.publish(principal: principal, signer: signer, direct: direct, wireGuard: wireGuard, client: client,
                                   logger: logger)
            }
        } else {
            logger.error("phone link: no install signer; the direct key is not published")
        }
        return port
    }

    /// Stops serving and closes every socket. Final.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        uplinkTask?.cancel()
        publishTask?.cancel()
        uplinkTask = nil
        publishTask = nil
        await assembly?.stop()
        await socket.close()
        await mirror?.stop()
        await userClient?.stop()
        await daemon?.close()
        assembly = nil
        mirror = nil
        userClient = nil
        daemon = nil
    }

    // MARK: Private

    /// `wss://` on the API origin.
    static func socketURL(_ base: URL, path: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = path
        return components.url ?? base
    }

    /// Serves the host role on `HostDO` until cancelled: connect, run the
    /// uplink until the socket closes, then reconnect after a backoff.
    private static func runUplink(principal: MobileLinkHostPrincipal, account: any MobileLinkHostAccount, host: MobileHost,
                                  box: HostSocketBox, channel: SignalFrameChannel, appVersion: String, logger: Logger) async {
        var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
        // wakeup-allow: each turn awaits a socket session or a Backoff wait after a failure; ends on cancellation.
        while true {
            do {
                let token = try await account.installToken()
                let socket = try await ControlPlaneHostSocket.connect(
                    transport: URLSessionControlPlaneTransport(),
                    baseURL: socketURL(principal.apiBaseURL, path: "/"), hostID: principal.hostID, token: token)
                await box.set(socket)
                let uplink = HostControlUplink(socket: socket, host: host, install: principal.install, appVersion: appVersion,
                                               signaling: channel)
                backoff.reset()
                try await uplink.run()
                await box.set(nil)
            } catch is CancellationError {
                return
            } catch {
                await box.set(nil)
                logger.error("phone link: host socket failed: \(String(describing: error), privacy: .public)")
            }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "mobile-link.uplink") } catch { return }
        }
    }

    /// Publishes this Mac's `direct` (and with B3, `wg`) certificate with
    /// its host id, so phones of the account pin the keys (b6-pairing.md 3).
    private static func publish(principal: MobileLinkHostPrincipal, signer: any LinkKeySigning, direct: DirectIdentity,
                                wireGuard: WireGuardPrivateKey?, client: ControlPlaneClient, logger: Logger) async {
        let issuer = LinkCertificateIssuer(environment: principal.environment, user: principal.accountUserID,
                                           install: principal.install, signer: signer)
        let pairing = PairingClient(client: client)
        do {
            let cert = try await issuer.issue(purpose: .direct, key: direct.publicKey.rawRepresentation)
            try await pairing.publish(cert, host: principal.hostID)
            if let wireGuard {
                let wg = try await issuer.issue(purpose: .wg, key: wireGuard.publicKey.rawRepresentation)
                try await pairing.publish(wg, host: principal.hostID)
            }
        } catch {
            logger.error("phone link: publishing link certificates failed: \(String(describing: error), privacy: .public)")
        }
    }
}
