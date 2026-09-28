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
    /// Machines with a pause, resume or delete in flight. Their rows show
    /// progress and refuse a second action until the first settles.
    public private(set) var machineActionsInFlight: Set<String> = []
    /// The latest pause, resume or delete failure, with the machine it hit.
    public private(set) var lastMachineActionFailure: CloudMachineActionFailure?
    /// How many Cloud screens are on screen; the tunnel is wanted while > 0.
    public private(set) var visibleScreenCount = 0
    /// Whether any Cloud screen is on screen.
    public var sectionIsVisible: Bool { visibleScreenCount > 0 }
    /// Whether the authenticated shell holds the tunnel open.
    ///
    /// Cloud machines' workspaces live in the Workspaces tab beside every
    /// other computer's, so their terminals are used while no Cloud screen is
    /// visible. The composition root takes this lease while the account is
    /// signed in and owns at least one machine, which keeps an account with no
    /// machines from ever enrolling a tunnel peer.
    public private(set) var shellLeaseActive = false
    /// Whether the scene is in the foreground.
    public private(set) var isForeground = true

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
    /// Re-reads the list while a machine is still provisioning, so a new
    /// machine's row turns from Starting to Running on its own.
    private var provisioningPollTask: Task<Void, Never>?
    /// How often the list is re-read while a machine is provisioning.
    static let provisioningPollInterval: Duration = .seconds(5)
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
        visibilityDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.tunnelStarter = tunnelStarter
        self.connector = connector
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.approvalClock = approvalClock
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
        provisioningPollTask?.cancel()
        provisioningPollTask = nil
        reconcile()
    }

    /// The scene returned to the foreground.
    public func sceneWillEnterForeground() {
        isForeground = true
        scheduleProvisioningPollIfNeeded()
        reconcile()
    }

    /// Takes or releases the shell-wide tunnel lease. Idempotent.
    public func setShellLease(_ active: Bool) {
        guard shellLeaseActive != active else { return }
        shellLeaseActive = active
        reconcile()
    }

    /// Forgets everything tied to the signed-in account: the tunnel and its
    /// links, the machine list, and any in-flight create. The device identity
    /// stays persisted, because it belongs to the phone rather than the
    /// account, and re-enrolling under the next account reuses it.
    public func resetForSignOut() {
        shellLeaseActive = false
        listTask?.cancel()
        listTask = nil
        provisioningPollTask?.cancel()
        provisioningPollTask = nil
        stopTunnel()
        tunnel = .idle
        identity = nil
        machines = .idle
        availableMachineKinds = nil
        lastCreateFailure = nil
        pendingCreate = nil
        machineActionsInFlight = []
        lastMachineActionFailure = nil
    }

    // MARK: - Machine lifecycle

    /// Stops a machine's compute and billing, keeping its disk.
    @discardableResult
    public func pauseMachine(_ machine: CloudMachine) async -> Bool {
        await runMachineAction(.pause, on: machine) { try await $0.pauseMachine(id: machine.id) }
    }

    /// Brings a paused machine's compute back.
    @discardableResult
    public func resumeMachine(_ machine: CloudMachine) async -> Bool {
        await runMachineAction(.resume, on: machine) { try await $0.resumeMachine(id: machine.id) }
    }

    /// Deletes a machine and its disk. Its link closes first, so nothing keeps
    /// talking to a machine that is being destroyed.
    @discardableResult
    public func deleteMachine(_ machine: CloudMachine) async -> Bool {
        connections.removeValue(forKey: machine.id)?.close()
        return await runMachineAction(.delete, on: machine) { try await $0.deleteMachine(id: machine.id) }
    }

    /// Dismisses the last lifecycle failure.
    public func clearMachineActionFailure() {
        lastMachineActionFailure = nil
    }

    /// One path for every lifecycle action: refuses a second action on the
    /// same machine while one is running, records a failure against the
    /// machine it hit, and reconciles from the server's list afterwards rather
    /// than guessing the resulting state locally.
    private func runMachineAction(
        _ action: CloudMachineAction,
        on machine: CloudMachine,
        perform: (any CloudVMServing) async throws -> Void
    ) async -> Bool {
        guard machineActionsInFlight.insert(machine.id).inserted else { return false }
        defer { machineActionsInFlight.remove(machine.id) }
        do {
            try await perform(service)
            if lastMachineActionFailure?.machineID == machine.id { lastMachineActionFailure = nil }
            refreshMachines()
            return true
        } catch {
            lastMachineActionFailure = CloudMachineActionFailure(
                machineID: machine.id,
                action: action,
                failure: CloudSessionFailure.classify(error, stage: .list)
            )
            refreshMachines()
            return false
        }
    }

    /// Re-run enrollment after a failure.
    public func retryTunnel() {
        guard case .failed = tunnel else { return }
        tunnel = .idle
        reconcile()
    }

    private var wantsTunnel: Bool { (sectionIsVisible || shellLeaseActive) && isForeground }

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
        // The machine list is a control-plane read that needs no tunnel, so a
        // tunnel stop must not cancel it: backgrounding mid-refresh would
        // otherwise leave the list stuck loading.
        for connection in connections.values { connection.close() }
        connections.removeAll()
        liveTunnel = nil
        if case .failed = tunnel { return }
        tunnel = .idle
    }

    // MARK: - Machines

    /// Machine ids the user hid from their computers on this phone.
    ///
    /// Persisted locally and only as hidden ids, so a newly created machine is
    /// visible by default. This is the store behind the Computers screen's
    /// switch; the shell filters the workspace list from it.
    public var hiddenMachineIDs: Set<String> {
        Set((visibilityDefaults.array(forKey: visibilityDefaultsKey) as? [String]) ?? [])
    }

    /// Records whether a machine is hidden from the user's computers.
    public func setMachine(id: String, hidden: Bool) {
        var ids = hiddenMachineIDs
        if hidden { ids.insert(id) } else { ids.remove(id) }
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
                // A destroyed machine is gone; no screen should list it.
                self.machines = .loaded(catalog.machines.filter { $0.lifecycle != .destroyed })
                self.scheduleProvisioningPollIfNeeded()
            } catch {
                guard !Task.isCancelled else { return }
                self.machines = .failed(CloudSessionFailure.classify(error, stage: .list), previous: self.machines.elements)
            }
        }
    }

    /// Schedules one more list read while any machine is still provisioning
    /// and the app is in the foreground. Each read reschedules only if it is
    /// still needed, so the poll ends by itself once every machine settles.
    private func scheduleProvisioningPollIfNeeded() {
        provisioningPollTask?.cancel()
        provisioningPollTask = nil
        guard isForeground,
              machines.elements.contains(where: { $0.lifecycle == .provisioning }) else { return }
        let clock = approvalClock
        provisioningPollTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.provisioningPollInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshMachines()
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
