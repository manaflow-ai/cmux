import CmuxLink
@_spi(Testing) public import CmuxLinkDirect
@_spi(Testing) public import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay
import CmuxLinkWG
public import CmuxMobileConnect
public import CmuxMobileHost
import CmuxPairing

/// The Mac's side of the phone link (d1-terminal-ux.md section 2): B4's
/// `DirectAcceptor`, B2's `WebRTCAcceptor` and (DEV switch) B3's acceptor
/// merged into one B5 `MobileHost`, every one authorized by the same trust
/// store, and each session's carrier identity checked against its hello.
///
/// Single use like `MobileHost`: `stop()` is final.
public actor MobileHostAssembly {
    public nonisolated let host: MobileHost
    private let direct: DirectAcceptor
    private let webrtc: WebRTCAcceptor?
    private let datagrams: WebRTCDatagramListener?
    private let wireGuard: WireGuardOverWebRTCAcceptor?
    private let signaling: MobileHostSignaling?
    private let devices: any MobileTrustStore
    private var port: UInt16?
    private var stopped = false
    /// Bumped whenever a start or stop takes ownership. Checks after every
    /// suspension keep a stop from being undone by an in-flight start.
    private var lifetime: UInt64 = 0

    private struct Superseded: Error {}

    public init(credentials: MobileHostCredentials, trust: MobileHostTrust, daemon: any MobileDaemon,
                signaling: MobileHostSignaling?, options: MobileHostAssemblyOptions = MobileHostAssemblyOptions(),
                features: MobileHostFeatures = MobileHostFeatures()) {
        self.init(credentials: credentials, trust: trust, daemon: daemon, signaling: signaling, options: options,
                  features: features, directFaults: nil, webrtcFaults: nil)
    }

    @_spi(Testing)
    public init(credentials: MobileHostCredentials, trust: MobileHostTrust, daemon: any MobileDaemon,
                signaling: MobileHostSignaling?, options: MobileHostAssemblyOptions,
                features: MobileHostFeatures, directFaults: DirectFaultInjector?, webrtcFaults: WebRTCFaultInjector?) {
        let hostID = credentials.hostID
        direct = DirectAcceptor(identity: credentials.direct, hostID: hostID, configuration: options.listen,
                                authorizer: CmuxPairing.TrustStoreAuthorizer(lookup: trust.lookup, host: hostID),
                                faultInjector: directFaults)
        var acceptors: [any LinkAcceptor] = [direct]
        if let signaling, let identity = credentials.webrtc {
            let acceptor = WebRTCAcceptor(router: signaling.router, iceServers: signaling.iceServers, identity: identity,
                                          hostID: hostID, authorizer: trust.webrtc, configuration: options.webrtc,
                                          injector: webrtcFaults)
            webrtc = acceptor
            acceptors.append(acceptor)
        } else {
            webrtc = nil
        }
        if let signaling, options.wireGuardOverWebRTC, let key = credentials.wireGuard {
            let listener = WebRTCDatagramListener(router: signaling.router, iceServers: signaling.iceServers, hostID: hostID,
                                                  configuration: options.webrtc)
            let acceptor = WireGuardOverWebRTCAcceptor(identity: key, hostID: hostID,
                                                       underlays: WebRTCUnderlayListener(listener: listener),
                                                       authorizer: TrustStoreWireGuardAuthorizer(lookup: trust.lookup),
                                                       configuration: options.wireGuard)
            datagrams = listener
            wireGuard = acceptor
            acceptors.append(acceptor)
        } else {
            datagrams = nil
            wireGuard = nil
        }
        self.signaling = signaling
        devices = trust.devices
        let authorizer = CmuxMobileHost.TrustStoreAuthorizer(hostID: hostID, accountUserID: credentials.accountUserID,
                                                             store: trust.devices)
        host = MobileHost(configuration: features.configuration(hostID: hostID, accountUserID: credentials.accountUserID),
                          acceptor: MergedLinkAcceptor(acceptors), daemon: daemon, authorizer: authorizer,
                          handlers: features.handlers, linkConfiguration: options.link,
                          taskRunner: features.taskRunner, taskAttachments: features.taskAttachments,
                          keyResolver: TrustedKeyCarrierResolver(lookup: trust.lookup, hostID: hostID))
    }

    /// Starts every acceptor and the host; returns the direct port (for the
    /// Bonjour advertisement and the Mac's published endpoints).
    public func start() async throws -> UInt16 {
        if let port { return port }
        guard !stopped else { throw CancellationError() }
        lifetime &+= 1
        let run = lifetime
        do {
            let bound = try await direct.start()
            try ensureCurrent(run)
            await webrtc?.start()
            try ensureCurrent(run)
            await datagrams?.start()
            try ensureCurrent(run)
            await wireGuard?.start()
            try ensureCurrent(run)
            await host.start()
            try ensureCurrent(run)
            port = bound
            return bound
        } catch is Superseded {
            await stopResources()
            throw CancellationError()
        } catch {
            if run != lifetime { await stopResources() }
            throw error
        }
    }

    /// Stops accepting and closes every session. Final.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        lifetime &+= 1
        await stopResources()
    }

    private func ensureCurrent(_ run: UInt64) throws {
        guard !stopped, run == lifetime else { throw Superseded() }
    }

    private func stopResources() async {
        await host.stop()
        await direct.stop()
        await webrtc?.stop()
        datagrams?.stop()
        await wireGuard?.stop()
        if let devices = devices as? TrustStoreMobileDevices { await devices.stop() }
        await signaling?.close()
    }
}
