public import Foundation
public import Observation

/// Owns the phone's cloud tunnel and machine list for as long as the Cloud
/// section is on screen and the app is in the foreground.
///
/// Lifecycle (decision 5A): the tunnel comes up when the Cloud surface
/// appears, goes down when it disappears or the app backgrounds, and comes
/// back on foreground while it is still showing. "Showing" is a lease count:
/// every Cloud screen (section, catalog, terminal) holds one while on screen,
/// so pushing the catalog over the section does not drop the tunnel when the
/// section's own `onDisappear` fires. Every transition is a method call from
/// a view or scene-phase callback; nothing here uses timers.
@MainActor
@Observable
public final class CloudSessionController {
    /// The tunnel's state.
    public private(set) var tunnel: CloudTunnelPhase = .idle
    /// The account's machines.
    public private(set) var machines: CloudListPhase<CloudMachine> = .idle
    /// How many Cloud screens are on screen; the tunnel is wanted while > 0.
    public private(set) var visibleScreenCount = 0
    /// Whether any Cloud screen is on screen.
    public var sectionIsVisible: Bool { visibleScreenCount > 0 }
    /// Whether the scene is in the foreground.
    public private(set) var isForeground = true
    /// Whether the full-screen Cloud flow is presented. Set by the entry row,
    /// read by the presenter hosted on a stable container view, because a
    /// presentation modifier on a list row does not present reliably.
    public var isFlowPresented = false

    private let service: any CloudVMServing
    private let identityResolver: CloudDeviceIdentityResolver
    private let tunnelStarter: any CloudTunnelStarting
    private let connector: any CloudTerminalConnecting
    private let stateDirectory: URL
    private let deviceName: String
    private let approvalClock: any Clock<Duration>

    private var liveTunnel: (any CloudTunnel)?
    private var identity: CloudDeviceIdentity?
    private var startTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var listTask: Task<Void, Never>?
    private var connections: [String: CloudMachineConnection] = [:]

    /// Creates the controller.
    /// - Parameters:
    ///   - service: The `/api/vm` client.
    ///   - identityStore: Where the device identity persists.
    ///   - tunnelStarter: Starts the in-process tunnel.
    ///   - connector: Opens daemon links.
    ///   - stateDirectory: A private, persistent directory for the link
    ///     client's device identity and known daemons.
    ///   - deviceName: This phone's name, sent on enroll and attach.
    ///   - approvalClock: Paces first-contact approval polling; tests inject a test clock.
    public init(
        service: any CloudVMServing,
        identityStore: any CloudDeviceIdentityStoring,
        tunnelStarter: any CloudTunnelStarting,
        connector: any CloudTerminalConnecting,
        stateDirectory: URL,
        deviceName: String,
        approvalClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.tunnelStarter = tunnelStarter
        self.connector = connector
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.approvalClock = approvalClock
    }

    // MARK: - Lifecycle

    /// A Cloud screen (section, catalog, or terminal) came on screen.
    public func sectionDidAppear() {
        visibleScreenCount += 1
        reconcile()
    }

    /// A Cloud screen left the screen. The tunnel drops only when the last
    /// one is gone.
    public func sectionDidDisappear() {
        visibleScreenCount = max(0, visibleScreenCount - 1)
        reconcile()
    }

    /// The scene entered the background.
    public func sceneDidEnterBackground() {
        isForeground = false
        reconcile()
    }

    /// The scene returned to the foreground.
    public func sceneWillEnterForeground() {
        isForeground = true
        reconcile()
    }

    /// Re-run enrollment after a failure.
    public func retryTunnel() {
        guard case .failed = tunnel else { return }
        tunnel = .idle
        reconcile()
    }

    private var wantsTunnel: Bool { sectionIsVisible && isForeground }

    private func reconcile() {
        if wantsTunnel {
            guard case .idle = tunnel else { return }
            startTunnel()
        } else {
            stopTunnel()
        }
    }

    private func startTunnel() {
        startGeneration &+= 1
        let generation = startGeneration
        tunnel = .starting
        startTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<(CloudDeviceIdentity, any CloudTunnel), CloudSessionFailure>
            do {
                let identity = try identityResolver.resolve()
                let enrollment = try await service.enrollTunnel(
                    clientPublicKey: identity.keyPair.publicKey,
                    deviceFingerprint: identity.fingerprint,
                    deviceName: deviceName
                )
                let config = try WireGuardQuickConfig.make(enrollment: enrollment, privateKey: identity.keyPair.privateKey)
                let live = try await tunnelStarter.start(wgQuickConfig: config.text)
                result = .success((identity, live))
            } catch {
                result = .failure(CloudSessionFailure.classify(error, stage: .tunnel))
            }
            guard self.startGeneration == generation, self.wantsTunnel else {
                // Superseded or no longer wanted: the tunnel object drops here.
                return
            }
            switch result {
            case .success(let (identity, live)):
                self.identity = identity
                self.liveTunnel = live
                self.tunnel = .ready(fingerprint: identity.fingerprint)
                self.refreshMachines()
            case .failure(let failure):
                self.tunnel = .failed(failure)
            }
        }
    }

    private func stopTunnel() {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        listTask?.cancel()
        listTask = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        liveTunnel = nil
        if case .failed = tunnel { return }
        tunnel = .idle
    }

    // MARK: - Machines

    /// Reload the machine list.
    public func refreshMachines() {
        listTask?.cancel()
        machines = .loading(previous: machines.elements)
        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await service.listMachines()
                guard !Task.isCancelled else { return }
                self.machines = .loaded(rows)
            } catch {
                guard !Task.isCancelled else { return }
                self.machines = .failed(CloudSessionFailure.classify(error, stage: .list), previous: self.machines.elements)
            }
        }
    }

    /// The connection for `machine`, created on first use. Nil until the tunnel is ready.
    public func connection(for machine: CloudMachine) -> CloudMachineConnection? {
        guard case .ready = tunnel, let identity, let liveTunnel else { return nil }
        if let existing = connections[machine.id] { return existing }
        let connection = CloudMachineConnection(
            machine: machine,
            service: service,
            connector: connector,
            tunnel: liveTunnel,
            identity: identity,
            stateDirectory: stateDirectory,
            deviceName: deviceName,
            approvalClock: approvalClock
        )
        connections[machine.id] = connection
        return connection
    }
}
