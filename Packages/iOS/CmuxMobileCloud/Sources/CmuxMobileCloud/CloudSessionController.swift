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
    /// The server's plan, machine-count, and machine-size metadata.
    public private(set) var machineLimits: CloudMachineLimits?
    /// The server's create-time network policy catalog, when available.
    public private(set) var networkPolicyCatalog: CloudNetworkPresetCatalog?
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
    private var nextListReadTask: Task<Void, Never>?
    /// How often the list is re-read while a machine is provisioning.
    static let provisioningPollInterval: Duration = .seconds(5)
    /// How many successful provisioning polls are allowed before the list
    /// shows a retryable failure instead of polling forever.
    static let defaultProvisioningPollLimit = 60
    static let defaultListRetryLimit = 8
    private let tunnelStartupTimeout: Duration
    private let provisioningPollLimit: Int
    private let listRetryLimit: Int
    private var provisioningPollCount = 0
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
    ///   - tunnelStartupTimeout: Bounds identity, enrollment, config, and
    ///     tunnel startup as one recoverable operation.
    ///   - provisioningPollLimit: Bounds the number of five-second reads made
    ///     while a machine remains in `provisioning`.
    ///   - listRetryLimit: Bounds automatic retry reads after retryable list
    ///     failures; the visible Retry action remains available afterwards.
    public init(
        service: any CloudVMServing,
        identityStore: any CloudDeviceIdentityStoring,
        tunnelStarter: any CloudTunnelStarting,
        connector: any CloudTerminalConnecting,
        stateDirectory: URL,
        deviceName: String,
        approvalClock: any Clock<Duration> = ContinuousClock(),
        visibilityDefaults: UserDefaults = .standard,
        tunnelStartupTimeout: Duration = .seconds(30),
        provisioningPollLimit: Int = 60,
        listRetryLimit: Int = 8
    ) {
        self.service = service
        self.identityResolver = CloudDeviceIdentityResolver(store: identityStore)
        self.tunnelStarter = tunnelStarter
        self.connector = connector
        self.stateDirectory = stateDirectory
        self.deviceName = deviceName
        self.approvalClock = approvalClock
        self.visibilityDefaults = visibilityDefaults
        self.tunnelStartupTimeout = max(.milliseconds(1), tunnelStartupTimeout)
        self.provisioningPollLimit = max(1, provisioningPollLimit)
        self.listRetryLimit = max(1, listRetryLimit)
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
        nextListReadTask?.cancel()
        nextListReadTask = nil
        reconcile()
    }

    /// The scene returned to the foreground.
    public func sceneWillEnterForeground() {
        isForeground = true
        if case .failed(let failure, _) = machines, failure.isRetryable {
            refreshMachines()
        } else {
            scheduleProvisioningPollIfNeeded()
        }
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
        nextListReadTask?.cancel()
        nextListReadTask = nil
        listFailureCount = 0
        provisioningPollCount = 0
        stopTunnel()
        tunnel = .idle
        identity = nil
        machines = .idle
        availableMachineKinds = nil
        machineLimits = nil
        networkPolicyCatalog = nil
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

    /// Why the last attempt to reach `machineID`'s terminal service failed,
    /// or nil when it has not failed since it last succeeded.
    public func connectionFailure(for machineID: String) -> CloudSessionFailure? {
        connections[machineID]?.lastError
    }

    /// Bumped by ``retryConnections()``; the workspace bridge re-reads every
    /// machine's catalog when it changes.
    public private(set) var connectionRetryGeneration = 0

    /// The user asked to try again: a failed tunnel re-enrolls, and every
    /// machine whose link failed is re-dialed from scratch.
    public func retryConnections() {
        retryTunnel()
        for (id, connection) in connections where connection.lastError != nil {
            connection.close()
            connections.removeValue(forKey: id)
        }
        connectionRetryGeneration &+= 1
    }

    /// The user asked to reconnect one machine: a failed tunnel re-enrolls,
    /// and that machine's link is re-dialed from scratch even if it has not
    /// failed, since what it is showing may be stale.
    public func retryConnection(for machineID: String) {
        retryTunnel()
        connections.removeValue(forKey: machineID)?.close()
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
            let startup = Task<(CloudDeviceIdentity, any CloudTunnel), any Error> { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                let identity = try await self.identityResolver.resolve()
                let enrollment = try await self.service.enrollTunnel(
                    clientPublicKey: identity.keyPair.publicKey,
                    deviceFingerprint: identity.fingerprint,
                    tunnelPurpose: .terminal,
                    deviceName: self.deviceName
                )
                let config = try WireGuardQuickConfig.make(
                    enrollment: enrollment,
                    privateKey: identity.keyPair.privateKey
                )
                let live = try await self.tunnelStarter.start(wgQuickConfig: config.text)
                return (identity, live)
            }
            do {
                let value = try await CloudSystemVPNTaskTimeout(timeout: tunnelStartupTimeout).value(startup)
                result = .success(value)
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
        refreshMachines(resetProvisioningPollBudget: true)
    }

    /// Loads the create-time network choices. Network policy was added after
    /// the first Cloud deployment, so an unavailable endpoint leaves the
    /// create sheet in full-internet compatibility mode.
    public func refreshNetworkPolicyCatalog() async {
        guard let catalog = try? await service.networkPolicyCatalog() else { return }
        networkPolicyCatalog = catalog
    }

    private func refreshMachines(resetProvisioningPollBudget: Bool) {
        if resetProvisioningPollBudget {
            provisioningPollCount = 0
        }
        let previouslyKnownMachineIDs = Set(machines.elements.map(\.id))
        listTask?.cancel()
        machines = .loading(previous: machines.elements)
        listTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await service.listMachineCatalog()
                guard !Task.isCancelled else { return }
                self.listFailureCount = 0
                self.availableMachineKinds = catalog.availableKinds
                self.machineLimits = catalog.limits
                // A destroyed machine is gone; no screen should list it.
                let liveMachines = catalog.machines.filter { $0.lifecycle != .destroyed }
                self.reconcileConnectionsAndVisibility(
                    for: liveMachines,
                    previouslyKnownMachineIDs: previouslyKnownMachineIDs
                )
                self.machines = .loaded(liveMachines)
                self.scheduleProvisioningPollIfNeeded()
            } catch {
                guard !Task.isCancelled else { return }
                let failure = CloudSessionFailure.classify(error, stage: .list)
                self.listFailureCount += 1
                // The first transient failure retries quietly: right after
                // sign-in the session's tokens can be mid-refresh, and an
                // error that clears itself in a moment is not worth showing.
                if failure.isRetryable, self.listFailureCount == 1, self.machines.elements.isEmpty {
                    self.scheduleListRead(after: Self.listRetryDelay(afterFailures: 1))
                    return
                }
                self.machines = .failed(failure, previous: self.machines.elements)
                if failure.isRetryable, self.listFailureCount < self.listRetryLimit {
                    self.scheduleListRead(after: Self.listRetryDelay(afterFailures: self.listFailureCount))
                }
            }
        }
    }

    private func reconcileConnectionsAndVisibility(
        for machines: [CloudMachine],
        previouslyKnownMachineIDs: Set<String>
    ) {
        let liveMachineIDs = Set(machines.map(\.id))
        let staleConnectionIDs = connections.keys.filter {
            previouslyKnownMachineIDs.contains($0) && !liveMachineIDs.contains($0)
        }
        for id in staleConnectionIDs {
            connections.removeValue(forKey: id)?.close()
        }

        let storedHiddenIDs = hiddenMachineIDs
        let reconciledHiddenIDs = storedHiddenIDs.intersection(liveMachineIDs)
        guard storedHiddenIDs != reconciledHiddenIDs else { return }
        visibilityDefaults.set(Array(reconciledHiddenIDs).sorted(), forKey: visibilityDefaultsKey)
    }

    /// Schedules one more list read while any machine is still provisioning
    /// and the app is in the foreground. A bounded budget turns a provider
    /// that never settles into the same retryable failure row used by other
    /// list errors.
    private func scheduleProvisioningPollIfNeeded() {
        nextListReadTask?.cancel()
        nextListReadTask = nil
        guard machines.elements.contains(where: { $0.lifecycle == .provisioning }) else {
            provisioningPollCount = 0
            return
        }
        guard provisioningPollCount < provisioningPollLimit else {
            machines = .failed(
                CloudSessionFailure(
                    kind: .other,
                    detail: "The machine is still provisioning after the retry window.",
                    action: "Refresh to check again."
                ),
                previous: machines.elements
            )
            return
        }
        provisioningPollCount += 1
        scheduleListRead(after: Self.provisioningPollInterval)
    }

    /// Consecutive failed list reads, which pace the retry.
    private var listFailureCount = 0

    /// The wait before re-reading the list after `failures` failed reads in a
    /// row: two seconds, then 5 s doubling to a minute.
    static func listRetryDelay(afterFailures failures: Int) -> Duration {
        failures <= 1 ? .seconds(2) : .seconds(min(5 << min(failures - 2, 4), 60))
    }

    /// Schedules the one pending list read, replacing any other. Only while
    /// in the foreground; returning there re-reads anything left unsettled.
    private func scheduleListRead(after delay: Duration) {
        nextListReadTask?.cancel()
        nextListReadTask = nil
        guard isForeground else { return }
        let clock = approvalClock
        nextListReadTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshMachines(resetProvisioningPollBudget: false)
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
