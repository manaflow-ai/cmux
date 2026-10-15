import CmuxCloud
import CmuxSettings
import Combine
import Foundation

/// The outcome of one Cloud Secrets sync to one machine. Names only: a value never
/// leaves the vault except inside the end-to-end env delivery.
struct CloudSecretSyncResult: Equatable, Sendable {
    let machineID: String
    /// Names delivered (the whole effective set; the receiver merges).
    let sent: [String]
    /// Names removed from the machine's env file because no scope applies any more.
    let removed: [String]
    /// True when the machine already had everything and nothing was sent.
    let noop: Bool
    /// True when this sync configured the machine's git credential helper for GitHub.
    let configuredGitCredentials: Bool
    /// Redacted, human-readable failure text, or nil on success.
    let error: String?

    var succeeded: Bool { error == nil }
}

/// The app's owner of Cloud Secrets: the Keychain vault on this Mac plus delivery to
/// Cloud machines. Every entrypoint (the sheet, the menus, `cmux vm secrets`, `cmux vm
/// agent`, machine creation) goes through this one service, so the vault has one writer
/// and one sync path.
///
/// Values enter through ``set(_:scope:source:sync:)`` and leave only through
/// `CmuxTuiSurfaceProvider.deliverEnvironment`, over the machine's end-to-end link into
/// its `cmux env receive`. Removal and the git credential helper run names-only commands
/// over `vm.exec`. Nothing here logs, publishes, or returns a value.
@MainActor
final class CloudSecretsService: ObservableObject {
    /// Delivery seams. Production talks to the machine's cmux-tui link and `vm.exec`;
    /// tests inject recorders.
    struct Transport: Sendable {
        /// Delivers `entries` into the machine's `~/.config/cmux/env` (merge semantics).
        var deliver: @Sendable (_ machineID: String, _ entries: [CloudEnvDelivery.Entry]) async throws -> Void
        /// Runs a names-only shell command on the machine.
        var exec: @Sendable (_ machineID: String, _ command: String) async throws -> VMExecResult
    }

    static let shared = CloudSecretsService(
        vault: CloudSecretVault(storage: sharedStorage),
        transport: .live
    )

    /// The app's Keychain vault item.
    static let keychainStorage = KeychainCloudSecretVaultStorage(
        service: KeychainCloudSecretVaultStorage.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
    )

    /// The Keychain item plus a non-secret marker in this bundle's support directory
    /// saying whether a vault exists (see `activateForApp`).
    static let sharedStorage = PresenceMarkedCloudSecretVaultStorage(
        base: keychainStorage,
        markerURL: supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier)
            .appendingPathComponent("cloud-secrets.present")
    )

    /// `Application Support/cmux/<bundle id>`, the directory the app's other
    /// per-bundle files use.
    nonisolated static func supportDirectory(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent(bundleIdentifier ?? "cmux", isDirectory: true)
    }

    /// Posted on the main queue after any vault or delivery change. No user info.
    static let didChangeNotification = Notification.Name("cmux.cloudSecrets.didChange")

    /// Secret metadata (never values), sorted by scope then name.
    @Published private(set) var records: [CloudSecretRecord] = []
    /// The per-machine delivery ledger.
    @Published private(set) var deliveries: [CloudSecretDelivery] = []
    /// Machines with a sync in flight.
    @Published private(set) var syncingMachineIDs: Set<String> = []
    /// The names each project declares, as last read from a checkout of it by
    /// `vm.secrets_check` (the check `cmux vm clone` runs). Names and
    /// descriptions only, kept for this process, so the sheet opened from that
    /// project's machine can list what is still unset without reading the
    /// machine's files.
    private(set) var declaredRequirementsByProject: [String: [CloudSecretRequirement]] = [:]
    /// Why the vault could not be read, already redacted; nil when it loaded.
    @Published private(set) var loadError: String?

    let vault: CloudSecretVault
    let transport: Transport
    let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let autoSyncKey = CloudCatalogSection().secretsAutoSync
    /// The newest sync per machine; a new request chains after it so one machine
    /// never receives two deliveries at once.
    private var syncChains: [String: (token: UUID, task: Task<CloudSecretSyncResult, Never>)] = [:]
    /// Machines forgotten in this process: a sync still in flight for one must not
    /// re-create its routing marker, and no new sync starts for it.
    private(set) var forgottenMachineIDs: Set<String> = []
    private var createObserver: NSObjectProtocol?
    /// Keeps the "Get started" card's secret count current; see `activateForApp`.
    var bridgeSubscription: AnyCancellable?

    init(
        vault: CloudSecretVault,
        transport: Transport,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        observesMachineCreation: Bool = true
    ) {
        self.vault = vault
        self.transport = transport
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        if observesMachineCreation {
            // A create that also opened the machine is the moment its link is up:
            // deliver then, so the first terminal and agent already have the keys.
            createObserver = notificationCenter.addObserver(
                forName: MachineCreateCoordinator.didChangeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let finished = notification.userInfo?[MachineCreateCoordinator.finishedUserInfoKey] as? MachineCreateCoordinator.Finished
                MainActor.assumeIsolated {
                    guard let self, let finished else { return }
                    switch finished.outcome {
                    case .created(let machineID?, _), .createdButOpenFailed(let machineID, _):
                        self.scheduleAutoSync(machineID: machineID)
                    case .created(nil, _), .failed:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Settings

    /// Whether secrets are delivered on machine creation and after every change.
    var isAutoSyncEnabled: Bool {
        get { autoSyncKey.value(in: defaults) }
        set {
            autoSyncKey.set(newValue, in: defaults)
            objectWillChange.send()
        }
    }

    // MARK: - Reading

    /// Re-reads records and the ledger from the vault.
    func reload() async {
        do {
            let loadedRecords = try await vault.records()
            let loadedDeliveries = try await vault.deliveries()
            // Clear the error before publishing records: `records` observers read it.
            loadError = nil
            records = loadedRecords
            deliveries = loadedDeliveries
        } catch {
            loadError = Self.redactedMessage(for: error, values: [])
        }
    }

    /// Records what a checkout of `projectKey` declares; an empty list forgets it.
    func rememberDeclaredRequirements(_ requirements: [CloudSecretRequirement], projectKey: String) {
        declaredRequirementsByProject[projectKey] = requirements.isEmpty ? nil : requirements
    }

    /// The ledger entry for one machine, from the last reload.
    func delivery(for machineID: String) -> CloudSecretDelivery? {
        deliveries.first { $0.machineID == machineID }
    }

    /// Per-name state on a machine. With `verify`, the machine's env file is read
    /// (names only, `cmux env ls --json` over `vm.exec`) instead of trusting the ledger.
    func status(machineID: String, verify: Bool) async throws -> [CloudSecretMachineStatusRow] {
        var namesOnMachine: Set<String>?
        if verify {
            let result = try await transport.exec(machineID, Self.envListCommand)
            namesOnMachine = try Self.parseEnvListNames(result, machineID: machineID)
        }
        return try await vault.status(machineID: machineID, namesOnMachine: namesOnMachine)
    }

    // MARK: - Writing

    /// What ``set(_:scope:source:sync:)`` would change, without storing anything.
    func preview(_ inputs: [CloudSecretInput], scope: CloudSecretScope) async throws -> [CloudSecretChange] {
        try await vault.preview(inputs, scope: scope)
    }

    /// Stores `inputs` in `scope`. With `sync` (and auto-sync on, or `sync` forced by the
    /// caller), every stale machine is brought up to date before returning, even when
    /// nothing changed: a machine a failed sync left behind still gets the value.
    @discardableResult
    func set(
        _ inputs: [CloudSecretInput],
        scope: CloudSecretScope,
        source: CloudSecretSource,
        sync: Bool
    ) async throws -> (changes: [CloudSecretChange], synced: [CloudSecretSyncResult]) {
        let changes = try await vault.set(inputs, scope: scope, source: source)
        await reload()
        postDidChange()
        let synced = sync ? await syncAllStale() : []
        return (changes, synced)
    }

    /// Removes `names` from `scope`, then (with `sync`) removes them from every machine
    /// that no longer gets them from another scope and brings every other stale
    /// machine up to date, even when nothing was removed.
    @discardableResult
    func remove(
        names: [String],
        scope: CloudSecretScope,
        sync: Bool
    ) async throws -> (changes: [CloudSecretChange], synced: [CloudSecretSyncResult]) {
        let changes = try await vault.remove(names: names, scope: scope)
        await reload()
        postDidChange()
        let synced = sync ? await syncAllStale() : []
        return (changes, synced)
    }

    /// Links a machine to a project so that project's secrets apply to it.
    func link(machineID: String, projectKey: String) async throws {
        try await vault.linkMachine(machineID, projectKey: projectKey)
        await reload()
        postDidChange()
    }

    /// Unlinks a machine from a project.
    func unlink(machineID: String, projectKey: String) async throws {
        try await vault.unlinkMachine(machineID, projectKey: projectKey)
        await reload()
        postDidChange()
    }

    /// Forgets a destroyed machine: its ledger entry and machine-scoped secrets.
    /// A sync in flight for it is cancelled, and whatever it still finishes is not
    /// recorded (the vault ignores its ledger writes, the service its routing marker).
    func forgetMachine(_ machineID: String) {
        forgottenMachineIDs.insert(machineID)
        syncChains.removeValue(forKey: machineID)?.task.cancel()
        syncingMachineIDs.remove(machineID)
        forgetProviderRouting(machineID: machineID)
        Task { @MainActor in
            do {
                try await self.vault.forgetMachine(machineID)
            } catch {
#if DEBUG
                cmuxDebugLog("cloudSecrets.forget.failed error=\(type(of: error))")
#endif
            }
            await self.reload()
            self.postDidChange()
        }
    }

    // MARK: - Sync

    /// Brings one machine up to date. A project key, when given, is linked first.
    /// Concurrent requests for the same machine run one after another; the later one is
    /// a fast no-op when the earlier already delivered everything.
    func sync(machineID: String, projectKey: String? = nil) async -> CloudSecretSyncResult {
        if forgottenMachineIDs.contains(machineID) {
            return CloudSecretSyncResult(machineID: machineID, sent: [], removed: [], noop: true, configuredGitCredentials: false, error: nil)
        }
        if let projectKey, !projectKey.isEmpty {
            do {
                try await vault.linkMachine(machineID, projectKey: projectKey)
            } catch {
                return CloudSecretSyncResult(
                    machineID: machineID, sent: [], removed: [], noop: false,
                    configuredGitCredentials: false,
                    error: Self.redactedMessage(for: error, values: [])
                )
            }
        }
        let previous = syncChains[machineID]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] () -> CloudSecretSyncResult in
            _ = await previous?.value
            guard let self else {
                return CloudSecretSyncResult(machineID: machineID, sent: [], removed: [], noop: true, configuredGitCredentials: false, error: nil)
            }
            return await self.performSync(machineID: machineID)
        }
        syncChains[machineID] = (token, task)
        syncingMachineIDs.insert(machineID)
        let result = await task.value
        if syncChains[machineID]?.token == token {
            syncChains[machineID] = nil
            syncingMachineIDs.remove(machineID)
        }
        return result
    }

    /// Syncs every machine in the ledger whose plan is not a no-op, or whose
    /// provider routing (``CloudSecretsProviderRouting``) is not applied yet: a
    /// machine that received a provider key before routing existed gets it here.
    @discardableResult
    func syncAllStale() async -> [CloudSecretSyncResult] {
        var machineIDs: [String] = []
        do {
            for delivery in try await vault.deliveries() {
                if try await machineNeedsSync(delivery.machineID) {
                    machineIDs.append(delivery.machineID)
                }
            }
        } catch {
            loadError = Self.redactedMessage(for: error, values: [])
            return []
        }
        var results: [CloudSecretSyncResult] = []
        for machineID in machineIDs {
            results.append(await sync(machineID: machineID))
        }
        return results
    }

    /// Delivers secrets to a new machine in the background when auto-sync is on and
    /// Cloud is allowed. Safe to call from every create path; syncs coalesce per machine.
    func scheduleAutoSync(machineID: String) {
        guard !machineID.isEmpty, isAutoSyncEnabled,
              !ManagedDevicePolicy().isEnforced(.disableCloud),
              CloudMachinesFeature.offMainIsEnabled() else { return }
        Task { @MainActor in
            _ = await self.sync(machineID: machineID)
        }
    }

    func postDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }
}
