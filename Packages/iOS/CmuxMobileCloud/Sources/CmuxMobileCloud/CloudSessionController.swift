public import Foundation
public import Observation

/// Owns the phone's Cloud tunnel while an authenticated shell is visible and
/// the app is in the foreground. The shell holds a visibility lease above
/// the tabs, so tab changes and navigation pushes keep the connection alive.
@MainActor
@Observable
public final class CloudSessionController {
    /// The tunnel's state.
    public private(set) var tunnel: CloudTunnelPhase = .idle
    /// The account's machines.
    public private(set) var machines: CloudListPhase<CloudMachine> = .idle
    /// The kinds the current deployment can create, when the API reports them.
    public private(set) var availableMachineKinds: Set<CloudMachineKind>?
    /// Whether a new machine is being provisioned.
    public private(set) var isCreatingMachine = false
    /// The latest create failure, shown beside the create action.
    public private(set) var lastCreateFailure: CloudSessionFailure?
    /// How many Cloud screens are on screen; the tunnel is wanted while > 0.
    public private(set) var visibleScreenCount = 0
    /// Optional system VPN, with its own enrollment and OS-managed lifetime.
    public let systemVPN: CloudSystemVPNController?
    /// Whether any Cloud screen is on screen.
    public var sectionIsVisible: Bool { visibleScreenCount > 0 }
    /// Whether the scene is in the foreground.
    public private(set) var isForeground = true
    /// Cloud machines selected for the shared Computers/workspace picker.
    /// A fresh install shows every machine. Hidden machine ids are persisted
    /// locally, so newly-created machines remain visible by default.
    public var visibleMachines: [CloudMachine] {
        machines.elements.filter(isMachineVisible)
    }

    private let service: any CloudVMServing
    private let identityResolver: CloudDeviceIdentityResolver
    private let tunnelStarter: any CloudTunnelStarting
    private let connector: any CloudTerminalConnecting
    private let stateDirectory: URL
    private let deviceName: String
    private let approvalClock: any Clock<Duration>
    private let visibilityDefaults: UserDefaults
    private let visibilityDefaultsKey = "mobile.cloud.hiddenMachineIDs.v2"

    private var liveTunnel: (any CloudTunnel)?
    private var identity: CloudDeviceIdentity?
    private var startTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var listTask: Task<Void, Never>?
    private var connections: [String: CloudMachineConnection] = [:]
    private var pendingCreate: (options: CloudMachineCreateOptions, idempotencyKey: String)?

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
        approvalClock: any Clock<Duration> = ContinuousClock(),
        systemVPN: CloudSystemVPNController? = nil,
        visibilityDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.tunnelStarter = tunnelStarter
        self.connector = connector
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.approvalClock = approvalClock
        self.systemVPN = systemVPN
        self.visibilityDefaults = visibilityDefaults
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
                let identity = try await identityResolver.resolve()
                let enrollment = try await service.enrollTunnel(
                    clientPublicKey: identity.keyPair.publicKey,
                    deviceFingerprint: identity.fingerprint,
                    tunnelPurpose: .terminal,
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

    /// Returns whether a machine is included in the shared computer picker.
    public func isMachineVisible(_ machine: CloudMachine) -> Bool {
        let hidden = visibilityDefaults.array(forKey: visibilityDefaultsKey) as? [String] ?? []
        return !hidden.contains(machine.id)
    }

    /// Includes or excludes a Cloud machine from the shared picker. The
    /// default state is all machines visible, so only hidden ids are stored.
    public func setMachineVisible(_ machine: CloudMachine, visible: Bool) {
        var ids = Set((visibilityDefaults.array(forKey: visibilityDefaultsKey) as? [String]) ?? [])
        if visible { ids.remove(machine.id) } else { ids.insert(machine.id) }
        visibilityDefaults.set(Array(ids).sorted(), forKey: visibilityDefaultsKey)
    }

    /// Reload the machine list.
    public func refreshMachines() {
        listTask?.cancel()
        machines = .loading(previous: machines.elements)
        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await service.listMachineCatalog()
                guard !Task.isCancelled else { return }
                self.availableMachineKinds = catalog.availableKinds
                self.machines = .loaded(catalog.machines)
            } catch {
                guard !Task.isCancelled else { return }
                self.machines = .failed(CloudSessionFailure.classify(error, stage: .list), previous: self.machines.elements)
            }
        }
    }

    /// Provision a Cloud machine through the control plane. The server owns
    /// team resolution and image selection; the phone only sends a kind and a
    /// stable retry key. A failed retry with the same options reuses its key,
    /// so a provider create cannot be duplicated by a client timeout.
    @discardableResult
    public func createMachine(options: CloudMachineCreateOptions = .init()) async -> CloudMachine? {
        guard !isCreatingMachine else { return nil }
        isCreatingMachine = true
        lastCreateFailure = nil
        defer { isCreatingMachine = false }
        let idempotencyKey: String
        if let pendingCreate, pendingCreate.options == options {
            idempotencyKey = pendingCreate.idempotencyKey
        } else {
            idempotencyKey = UUID().uuidString
            pendingCreate = (options, idempotencyKey)
        }
        do {
            let machine = try await service.createMachine(options: options, idempotencyKey: idempotencyKey)
            pendingCreate = nil
            refreshMachines()
            return machine
        } catch {
            lastCreateFailure = CloudSessionFailure.classify(error, stage: .list)
            return nil
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
