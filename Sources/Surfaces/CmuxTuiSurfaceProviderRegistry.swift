import CmuxFoundation
import CmuxSettings
import Foundation

/// Owns one ``CmuxTuiSurfaceProvider`` per cloud machine and keeps the catalog's machine
/// list in step with the control plane: registers a provider for every machine the
/// account can see, unregisters deleted ones, and drives refreshes on the same 45 s
/// cadence the Machines panel uses. Signing out tears everything down.
///
/// Authenticated fleet discovery also prepares the shared terminal carrier, even for
/// an empty fleet. Both follow the Cloud flag and Beta Features opt-in; disabling
/// Cloud or signing out stops the carrier without deleting persisted identities.
@MainActor
final class CmuxTuiSurfaceProviderRegistry {
    static let shared = CmuxTuiSurfaceProviderRegistry()

    private var catalog: SurfaceCatalog?
    private var providers: [String: CmuxTuiSurfaceProvider] = [:]
    private let links: CloudMachineLinkManager
    /// The app's one WireGuard hub for private-network machines; nil when no cmux-tui
    /// client is bundled (then no link can be made at all).
    nonisolated let wireGuardHub: CloudWireGuardHub?
    /// Loopback forwards to VM ports over the hub (Ports and Desktop rows); nil
    /// without a hub. One table for the fleet so a (machine, port) keeps its
    /// local port until the machine leaves the fleet or the account signs out.
    let portAccess = CloudPortAccessStore()
    let portForwards: CloudHubPortForwarder?
    private var pollTask: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var featureFlagObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    /// Whether the periodic fleet read may run right now.
    private let isCloudEnabled: @MainActor () -> Bool
    private let allowsBackgroundWork: @MainActor () -> Bool
    private let listPage: @MainActor () async -> VMListPage?
    private let refreshProvider: @MainActor (CmuxTuiSurfaceProvider, Bool) async -> Bool
    private let closeTransports: @MainActor () async -> Void
    private var refreshInFlight: Task<Bool, Never>?
    private var discoveryInFlight: Task<[CmuxTuiSurfaceProvider]?, Never>?
    /// New account discovery waits until the previous account's transports close.
    private var teardownInFlight: Task<Void, Never>?
    /// A forced refresh waits for an existing pass instead of starting a second
    /// fleet read. This prevents an older page from unregistering a machine that
    /// a newer page just added.
    private var refreshGeneration: UInt64 = 0
    /// Bumped by every ``start(catalog:)``. `NotificationCenter` blocks queued
    /// on `.main` are already enqueued when `removeObserver` runs, so a
    /// teardown posted before a restart can still land after it. The observer
    /// carries the epoch it was registered with and a stale one is dropped:
    /// without this, a `DisableCloud` teardown that lands just after the
    /// policy lifts would clear the freshly restarted registry.
    private var accessEpoch: UInt64 = 0
    /// Create receipts also end at team changes, which preserve the registry's observer epoch.
    private var creationEpoch = UUID()
    /// Machine IDs admitted from a successful create response remain owned by
    /// this registry until a fleet page positively observes them. A stale page
    /// must not prune a receipt that is still converging into discovery.
    private var pendingMachineCreationIDs: Set<String> = []; private var hasCompletedInitialRefresh = false; private var refreshedMachineIDs: Set<SurfaceMachineID> = []
    /// Whether account access has ended. Retired registries reject all new Cloud work
    /// until ``start(catalog:)`` reactivates them for the next account.
    private var isRetired = true
    private let pollInterval: Duration = .seconds(45)
    /// In-flight forward and link teardowns for deleted machines, keyed by
    /// machine id; sign-out waits for them before stopping the hub.
    private var machineTeardowns: [String: Task<Void, Never>] = [:]
    private var featureResumeTask: Task<Void, Never>?
    private var featureSuspensionTask: Task<Void, Never>?
    private var isFeatureSuspended = false
    init(
        links: CloudMachineLinkManager,
        wireGuardHub: CloudWireGuardHub? = nil,
        isCloudEnabled: @escaping @MainActor () -> Bool = { true },
        allowsBackgroundWork: @escaping @MainActor () -> Bool = { true },
        listPage: @escaping @MainActor () async -> VMListPage? = { nil },
        refreshProvider: @escaping @MainActor (CmuxTuiSurfaceProvider, Bool) async -> Bool = { provider, force in
            await provider.refreshCurrentGraph(force: force)
        },
        closeTransports: (@MainActor () async -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.links = links
        self.wireGuardHub = wireGuardHub
        self.isCloudEnabled = isCloudEnabled
        self.allowsBackgroundWork = allowsBackgroundWork
        self.listPage = listPage
        self.refreshProvider = refreshProvider
        self.notificationCenter = notificationCenter
        let forwards = wireGuardHub.map { CloudHubPortForwarder(dialer: CloudWireGuardHubDialer(hub: $0)) }
        portForwards = forwards
        self.closeTransports = closeTransports ?? {
            await forwards?.closeAll()
            await links.disconnectAll()
            await wireGuardHub?.stop()
        }
        featureFlagObserver = notificationCenter.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPollingToActivationPolicy() }
        }
    }
    /// Captured before a create starts, so a late receipt cannot enter another account.
    var creationScope: UUID? { !isRetired && isCloudEnabled() ? creationEpoch : nil }

    /// Publishes the create response's friendly name before the first workspace bind.
    /// The response need not contain private addresses; provider discovery still
    /// owns transport initialization and registration.
    func recordCreatedMachine(_ summary: VMSummary, scope: UUID?) {
        guard let scope, scope == creationScope, let catalog else { return }
        // A replay cannot overwrite names or status already accepted by discovery.
        guard catalog.machines[.cloud(summary.id)] == nil else { return }
        pendingMachineCreationIDs.insert(summary.id)
        catalog.admitMachineCreationReceipt(CmuxTuiSurfaceProvider.info(
            from: summary, linkState: .connecting, linkError: nil, stats: nil
        ))
    }

    /// True while the periodic fleet read is scheduled.
    var isPolling: Bool { pollTask != nil }

    deinit {
        if let accessObserver { notificationCenter.removeObserver(accessObserver) }
        if let themeObserver { notificationCenter.removeObserver(themeObserver) }
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        if let featureFlagObserver { notificationCenter.removeObserver(featureFlagObserver) }
        pollTask?.cancel()
        refreshInFlight?.cancel()
        discoveryInFlight?.cancel()
        featureSuspensionTask?.cancel()
    }

    /// Live headless links, for the Cloud tunnel's idle policy.
    func connectedCloudLinkCount() async -> Int {
        await links.connectedMachineCount
    }

    /// Restarts discovery for the current account and registers its Cloud machines.
    func start(catalog: SurfaceCatalog) {
        self.catalog = catalog
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return }
        pollTask?.cancel()
        pollTask = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        discoveryInFlight?.cancel()
        discoveryInFlight = nil
        isRetired = false
        accessEpoch &+= 1
        creationEpoch = UUID()
        pendingMachineCreationIDs.removeAll(); hasCompletedInitialRefresh = false; refreshedMachineIDs.removeAll()
        refreshGeneration &+= 1
        let epoch = accessEpoch
        // Replacing block observers prevents stale callbacks after a restart.
        if let accessObserver { notificationCenter.removeObserver(accessObserver) }
        accessObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.accessEpoch == epoch else { return }
                self.creationEpoch = UUID()
                if notification.userInfo?["cmux.teamSwitch"] as? Bool == true {
                    // Team switches synchronously revoke the old scope. The
                    // scope observer will later await full transport teardown,
                    // but no old discovery or provider refresh may publish in
                    // the interval before that await completes.
                    self.invalidateAccess()
                    return
                }
                Task { @MainActor in await self.accessDidEnd(epoch: epoch) }
            }
        }
        // A Ghostty config reload can change the resolved theme; re-push it so remote
        // panes keep matching the local ones (connect-time push covers new links).
        if let themeObserver { notificationCenter.removeObserver(themeObserver) }
        themeObserver = notificationCenter.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.links.pushHostThemeToConnectedLinks() }
        }
        // The Beta Features toggle can change while the app runs; the poll
        // follows it without a relaunch in both directions.
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = notificationCenter.addObserver(
            forName: RightSidebarBetaFeatureSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPollingToActivationPolicy() }
        }
        syncPollingToActivationPolicy()
    }

    /// Sign-in reactivates the same catalog only after old account resources close.
    func resumeAfterSignIn() async {
        let epoch = accessEpoch
        await teardownInFlight?.value
        guard epoch == accessEpoch, let catalog else { return }
        start(catalog: catalog)
    }

    /// Starts the periodic fleet read when background Cloud work is allowed and
    /// not yet running; cancels it when it is no longer allowed.
    func syncPollingToActivationPolicy() {
        guard !isRetired else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard isCloudEnabled() else {
            featureResumeTask?.cancel()
            featureResumeTask = nil
            refreshGeneration &+= 1
            pollTask?.cancel()
            pollTask = nil
            refreshInFlight?.cancel()
            refreshInFlight = nil
            discoveryInFlight?.cancel()
            discoveryInFlight = nil
            suspendCloudTransportsIfNeeded()
            return
        }
        if let pending = featureSuspensionTask {
            guard featureResumeTask == nil else { return }
            featureResumeTask = Task { @MainActor [weak self] in
                await pending.value
                guard let self, !Task.isCancelled, self.isCloudEnabled() else { return }
                self.featureResumeTask = nil
                self.featureSuspensionTask = nil
                self.isFeatureSuspended = false
                self.syncPollingToActivationPolicy()
            }
            return
        }
        isFeatureSuspended = false
        guard allowsBackgroundWork() else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        Task { await wireGuardHub?.prepareForCloudUse() }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                // The poll interval is the intended behavior (the list is not push-driven),
                // not a synchronization substitute.
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(45))
            }
        }
    }

    /// Re-reads the machine list and refreshes the providers discovered by that pass.
    /// Discovery has its own in-flight operation so opening a new machine never
    /// waits for this pass's unrelated link, snapshot, or stats requests.
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled() else { return false }
        let access = accessEpoch
        while true {
            guard access == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return false }
            if let inFlight = refreshInFlight {
                let listed = await inFlight.value
                if refreshInFlight == inFlight { refreshInFlight = nil }
                guard access == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return false }
                if !force { return listed }
                continue
            }
            let task = Task<Bool, Never> { [weak self] in
                guard let self, access == self.accessEpoch, !Task.isCancelled,
                      let discovered = await self.discoverMachines(force: force, updateExisting: true),
                      access == self.accessEpoch, !Task.isCancelled else { return false }
                let activeMachines = (force || !self.hasCompletedInitialRefresh) ? Set(discovered.map(\.machine)) : (self.catalog?.projectedMachines ?? []).union(self.catalog?.pendingRestoredMachineIDs.map(SurfaceMachineID.cloud) ?? []).union(self.pendingMachineCreationIDs.map(SurfaceMachineID.cloud)).union(Set(discovered.filter { !self.refreshedMachineIDs.contains($0.machine) || $0.info.linkState != .connected || $0.cloudState?.cursor == nil }.map(\.machine)))
                await withTaskGroup(of: Void.self) { group in
                    for provider in discovered where activeMachines.contains(provider.machine) {
                        group.addTask { @MainActor in
                            guard access == self.accessEpoch, !Task.isCancelled else { return }
                            let succeeded = await self.refreshProvider(provider, force); if succeeded, provider.isRegisteredInCatalog() { self.refreshedMachineIDs.insert(provider.machine) }
                        }
                    }
                }
                self.hasCompletedInitialRefresh = true; return access == self.accessEpoch && !Task.isCancelled
            }
            refreshInFlight = task
            let listed = await task.value
            if refreshInFlight == task { refreshInFlight = nil }
            guard access == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return false }
            return listed
        }
    }

    /// Serializes only fleet listing and registration. The returned provider
    /// snapshot belongs to this pass; a later discovery must not add more work
    /// to an older background refresh that is already serving its own callers.
    private func discoverMachines(force: Bool, updateExisting: Bool) async -> [CmuxTuiSurfaceProvider]? {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled() else { return nil }
        let epoch = accessEpoch
        await teardownInFlight?.value
        await featureSuspensionTask?.value
        while true {
            guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
            if let inFlight = discoveryInFlight {
                let discovered = await inFlight.value
                if discoveryInFlight == inFlight { discoveryInFlight = nil }
                guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
                // A registration-only pass has not applied known summaries.
                // A full refresh must list and apply its own page before linking.
                if !force && !updateExisting { return discovered }
                continue
            }
            refreshGeneration &+= 1
            let generation = refreshGeneration
            let task = Task<[CmuxTuiSurfaceProvider]?, Never> { [weak self] in
                guard let self, !self.isRetired, epoch == self.accessEpoch, !Task.isCancelled else { return nil }
                return await self.performDiscovery(generation: generation, updateExisting: updateExisting)
            }
            discoveryInFlight = task
            let discovered = await task.value
            if discoveryInFlight == task { discoveryInFlight = nil }
            guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
            return discovered
        }
    }

    func provider(machineID: String) -> CmuxTuiSurfaceProvider? {
        providers[machineID]
    }

    /// The provider for a machine that may have been created a moment ago (`cmux vm new`
    /// opens its terminal right after `POST /api/vm` returns): when the registry has not
    /// listed it yet, re-read the fleet once instead of failing with "no provider".
    func providerRefreshingIfMissing(machineID: String) async -> CmuxTuiSurfaceProvider? {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled() else { return nil }
        if let provider = providers[machineID] { return provider }
        let epoch = accessEpoch
        _ = await discoverMachines(force: true, updateExisting: false)
        guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
        return providers[machineID]
    }

    /// The machine is gone: drop its provider and catalog entry now, and tear
    /// down its forwards and link on a task the registry owns (awaited by
    /// ``accessDidEnd()``), so no caller has to hold an unstructured task.
    func machineWasDeleted(_ rawID: String) {
        // A fleet page fetched before the delete must not re-register the
        // machine on top of this teardown.
        refreshGeneration &+= 1
        unregisterMachine(rawID)
    }

    /// Deletion and discovery share ordered teardown without waiting for unrelated machines.
    private func unregisterMachine(_ rawID: String) {
        // Match the registered casing so every ownership table is removed.
        let id = registeredMachineID(matching: rawID)
        pendingMachineCreationIDs.remove(id); refreshedMachineIDs.remove(.cloud(id))
        let provider = providers.removeValue(forKey: id)
        provider?.suspendForFeatureFlag()
        catalog?.removeCloudMachine(.cloud(id))
        // Teardowns for one machine run in order: a repeated delete waits for
        // the earlier pass instead of racing it (cancellation would not stop
        // a pass already inside the managers), so a refresh that re-lists the
        // machine awaits the whole chain through the newest task.
        let previousTeardown = machineTeardowns[id]
        machineTeardowns[id] = Task { [links, portForwards, portAccess] in
            await previousTeardown?.value
            if let provider {
                await provider.stop()
            } else {
                await portAccess.remove(machineID: id)
            }
            await portForwards?.close(machineID: id)
            await links.disconnect(machineID: id)
        }
    }

    /// The id the registry stores for a machine, matched case-insensitively;
    /// the caller's spelling when nothing is registered under it.
    private func registeredMachineID(matching rawID: String) -> String {
        if providers[rawID] != nil { return rawID }
        let candidates = Set(providers.keys).union(machineTeardowns.keys).union(pendingMachineCreationIDs)
        return candidates.first { $0.caseInsensitiveCompare(rawID) == .orderedSame } ?? rawID
    }

    /// The headless link's local mux socket for a machine, connecting if needed.
    func linkSocketPath(machineID: String) async throws -> (socketPath: String, session: String) {
        guard isCloudEnabled() else {
            throw CloudMachineLinkManager.ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        let connected = try await links.connected(machineID: machineID)
        return (connected.socketPath, connected.session)
    }

    func privateRoute(machineID: String) async -> String? {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            return nil
        }
        let epoch = accessEpoch
        // The persisted device marker outlives this in-memory registry. An
        // explicit open must discover its machine before using the saved-device
        // shortcut, even when the first background fleet read has not run.
        guard await providerRefreshingIfMissing(machineID: machineID) != nil else { return nil }
        let route = await links.privateRoute(for: machineID)
        guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
        return route
    }

    func resolvedPrivateRoute(machineID: String, through hub: CloudWireGuardHub.Ready, fallbackRoute: String, addresses: [String]) async throws -> String {
        guard isCloudEnabled() else {
            throw CloudMachineLinkManager.ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        return try await links.resolvedPrivateRoute(machineID: machineID, through: hub, fallbackRoute: fallbackRoute, addresses: addresses)
    }

    /// Cancels Cloud-only transport work when the remote gate closes while
    /// retaining providers, catalog resources, and persisted pane identities.
    /// Re-enabling the gate reuses those providers on the next discovery pass.
    private func suspendCloudTransportsIfNeeded() {
        guard !isFeatureSuspended else { return }
        isFeatureSuspended = true
        let providers = Array(providers.values)
        for provider in providers { provider.suspendForFeatureFlag() }
        featureSuspensionTask?.cancel()
        featureSuspensionTask = Task { @MainActor [weak self] in
            for provider in providers { await provider.stop() }
            await self?.closeTransports()
        }
    }

    // MARK: - internals

    private func performDiscovery(generation: UInt64, updateExisting: Bool) async -> [CmuxTuiSurfaceProvider]? {
        guard !isRetired, let catalog, let page = await listPage() else { return nil }
        guard !isRetired, generation == refreshGeneration, isCloudEnabled(), !Task.isCancelled else { return nil }
        if allowsBackgroundWork() { await wireGuardHub?.prepareForCloudUse() }
        guard !isRetired, generation == refreshGeneration, isCloudEnabled(), !Task.isCancelled else { return nil }
        let seen = Set(page.vms.map(\.id))
        // This page is the authoritative positive observation for any receipt
        // it contains. Once observed, normal stale pruning may own that ID.
        pendingMachineCreationIDs.subtract(seen)
        // Reconcile both stores. A restored catalog can contain a machine for
        // which this process has not created a provider yet.
        let catalogMachineIDs = Set(catalog.machines.keys.compactMap(\.cloudMachineID))
        let staleIDs = Set(providers.keys)
            .union(catalogMachineIDs)
            .union(catalog.pendingRestoredMachineIDs)
            .subtracting(pendingMachineCreationIDs)
            .subtracting(seen)
        for id in staleIDs {
            unregisterMachine(id)
        }
        await links.retainAddresses(machineIDs: seen)
        guard !isRetired, generation == refreshGeneration else { return nil }
        for summary in page.vms {
            guard !isRetired else { return nil }
            // Missing-machine discovery owns registration and deletion only.
            // Updating a known provider invalidates its suspended snapshot;
            // only a full refresh may do that because it also restarts the work.
            if !updateExisting, providers[summary.id] != nil { continue }
            // A machine listed again after a delete waits for that delete's
            // teardown, so the teardown cannot close the new provider's
            // forwards or link.
            // `machineWasDeleted` keys teardowns by the id it resolved
            // case-insensitively; look the teardown up the same way.
            let registeredID = registeredMachineID(matching: summary.id)
            if let teardown = machineTeardowns.removeValue(forKey: registeredID) {
                await teardown.value
                guard generation == refreshGeneration else { return nil }
            }
            await links.setPrivateAddresses([summary.addressIPv4, summary.addressIPv6].compactMap { $0 }, for: summary.id)
            // A delete that ran while that await was suspended bumped the
            // generation; creating a provider now would hand its link and
            // forwards to the teardown that delete scheduled.
            guard generation == refreshGeneration else { return nil }
            if let provider = providers[summary.id] {
                provider.update(summary: summary)
            } else {
                let provider = CmuxTuiSurfaceProvider(
                    summary: summary, links: links, catalog: catalog,
                    portForwards: portForwards, portAccessStore: portAccess
                )
                providers[summary.id] = provider
                catalog.register(provider)
            }
        }
        return page.vms.compactMap { providers[$0.id] }
    }

    /// Notification-driven teardown. Ignored when it belongs to a registry
    /// generation an intervening ``start(catalog:)`` has already replaced.
    func accessDidEnd(epoch: UInt64) async {
        guard epoch == accessEpoch else { return }
        await accessDidEnd()
    }

    /// Synchronous publication fence shared by team switching and full teardown.
    private func invalidateAccess() {
        isRetired = true
        accessEpoch &+= 1
        creationEpoch = UUID()
        pendingMachineCreationIDs.removeAll(); hasCompletedInitialRefresh = false; refreshedMachineIDs.removeAll()
        refreshGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        discoveryInFlight?.cancel()
        discoveryInFlight = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        featureResumeTask?.cancel()
        featureResumeTask = nil
        // Suspend before unregistering so terminal callbacks cannot race a
        // catalog removal during account teardown.
        for provider in providers.values { provider.suspendForFeatureFlag() }
        let retiredIDs = Set(providers.keys).union(catalog?.machines.keys.compactMap(\.cloudMachineID) ?? [])
        for id in retiredIDs { catalog?.unregister(machine: .cloud(id)) }
    }

    func accessDidEnd() async {
        invalidateAccess()
        let suspension = featureSuspensionTask
        featureSuspensionTask = nil
        isFeatureSuspended = false
        let retiringProviders = providers
        providers.removeAll()
        let teardowns = Array(machineTeardowns.values)
        machineTeardowns.removeAll()
        let previous = teardownInFlight
        let teardown = Task { [closeTransports] in
            await previous?.value
            await suspension?.value
            await Self.stopRetiringProviders(Array(retiringProviders.values))
            for task in teardowns { await task.value }
            // Signing out drops the tunnel too: the next account enrolls its own.
            await closeTransports()
        }
        // Sign-in must observe this fence before any provider drain can suspend.
        teardownInFlight = teardown
        await teardown.value
        if teardownInFlight == teardown { teardownInFlight = nil }
    }
}
