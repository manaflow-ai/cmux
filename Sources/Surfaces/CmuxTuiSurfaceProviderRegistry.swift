import CmuxFoundation
import CmuxSettings
import Foundation

/// Owns one ``CmuxTuiSurfaceProvider`` per cloud machine and keeps the catalog's machine
/// list in step with the control plane: registers a provider for every machine the
/// account can see, unregisters deleted ones, and drives refreshes on the same 45 s
/// cadence the Machines panel uses. Signing out tears everything down.
///
/// The periodic fleet read is the only Cloud API traffic an idle app makes, so it
/// runs only while ``CloudActivationPolicy`` allows background Cloud work (Cloud
/// Machines on, or this Mac used Cloud before) and follows the Beta Features
/// toggle at runtime. Demand-driven reads (`refresh(force:)`, a `cmux vm` verb)
/// are explicit user actions and are not gated here.
@MainActor
final class CmuxTuiSurfaceProviderRegistry {
    static let shared = CmuxTuiSurfaceProviderRegistry()

    private var catalog: SurfaceCatalog?
    private var providers: [String: CmuxTuiSurfaceProvider] = [:]
    private let links: CloudMachineLinkManager
    /// The app's one WireGuard hub for private-network machines; nil when no cmux-tui
    /// client is bundled (then no link can be made at all).
    let wireGuardHub: CloudWireGuardHub?
    /// Loopback forwards to VM ports over the hub (Ports and Desktop rows); nil
    /// without a hub. One table for the fleet so a (machine, port) keeps its
    /// local port until the machine leaves the fleet or the account signs out.
    let portForwards: CloudHubPortForwarder?
    private var pollTask: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    /// Whether the periodic fleet read may run right now.
    private let allowsBackgroundWork: @MainActor () -> Bool
    private let listPage: @MainActor () async -> VMListPage?
    private let refreshProvider: @MainActor (CmuxTuiSurfaceProvider, Bool) async -> Void
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
    /// Whether account access has ended. Retired registries reject all new Cloud work
    /// until ``start(catalog:)`` reactivates them for the next account.
    private var isRetired = true
    /// Same cadence as the Machines panel's list refresh.
    private let pollInterval: Duration = .seconds(45)
    /// In-flight forward and link teardowns for deleted machines, keyed by
    /// machine id; sign-out waits for them before stopping the hub.
    private var machineTeardowns: [String: Task<Void, Never>] = [:]

    init(
        links: CloudMachineLinkManager,
        wireGuardHub: CloudWireGuardHub?,
        allowsBackgroundWork: @escaping @MainActor () -> Bool = { true },
        listPage: @escaping @MainActor () async -> VMListPage?,
        refreshProvider: @escaping @MainActor (CmuxTuiSurfaceProvider, Bool) async -> Void = { provider, force in
            await provider.refresh(force: force)
        },
        closeTransports: (@MainActor () async -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.links = links
        self.wireGuardHub = wireGuardHub
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
    }

    /// The production registry: one hub over the bundled client, shared by every link,
    /// polling only while the activation policy allows background Cloud work.
    convenience init() {
        let hub = CloudTuiClientPaths.clientURL().map { CloudWireGuardHub.production(clientURL: $0) }
        self.init(
            links: CloudMachineLinkManager(hub: hub),
            wireGuardHub: hub,
            allowsBackgroundWork: { CloudActivationPolicy.live().allowsBackgroundCloudWork },
            listPage: {
                guard let client = VMClient.shared else { return nil }
                return try? await client.listPage()
            }
        )
    }

    /// True while the periodic fleet read is scheduled.
    var isPolling: Bool { pollTask != nil }

    /// Kills the hub child synchronously; for `applicationWillTerminate`, where nothing
    /// may await and an orphaned hub would keep a WireGuard session alive after quit.
    nonisolated func terminateWireGuardHubForAppQuit() {
        wireGuardHub?.terminateForAppQuit()
    }

    /// Live headless links, for the Cloud tunnel's idle policy.
    func connectedCloudLinkCount() async -> Int {
        await links.connectedMachineCount
    }

    /// Registers this Mac's cloud machines with the catalog and starts polling.
    func start(catalog: SurfaceCatalog) {
        self.catalog = catalog
        guard !ManagedDevicePolicy().isEnforced(.disableCloud) else { return }
        isRetired = false
        accessEpoch &+= 1
        refreshGeneration &+= 1
        let epoch = accessEpoch
        // Block observers are retained by NotificationCenter: drop the previous
        // tokens so a re-start never leaves stale callbacks registered.
        if let accessObserver { notificationCenter.removeObserver(accessObserver) }
        accessObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.accessDidEnd(epoch: epoch) }
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
            Task { @MainActor in self?.syncPollingToActivationPolicy() }
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
        guard allowsBackgroundWork() else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
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
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud) else { return false }
        let access = accessEpoch
        while true {
            guard access == accessEpoch, !Task.isCancelled else { return false }
            if let inFlight = refreshInFlight {
                let listed = await inFlight.value
                if refreshInFlight == inFlight { refreshInFlight = nil }
                guard access == accessEpoch, !Task.isCancelled else { return false }
                if !force { return listed }
                continue
            }
            let task = Task<Bool, Never> { [weak self] in
                guard let self, access == self.accessEpoch, !Task.isCancelled,
                      let discovered = await self.discoverMachines(force: force, updateExisting: true),
                      access == self.accessEpoch, !Task.isCancelled else { return false }
                await withTaskGroup(of: Void.self) { group in
                    for provider in discovered {
                        group.addTask { @MainActor in
                            guard access == self.accessEpoch, !Task.isCancelled else { return }
                            await self.refreshProvider(provider, force)
                        }
                    }
                }
                return access == self.accessEpoch && !Task.isCancelled
            }
            refreshInFlight = task
            let listed = await task.value
            if refreshInFlight == task { refreshInFlight = nil }
            guard access == accessEpoch, !Task.isCancelled else { return false }
            return listed
        }
    }

    /// Serializes only fleet listing and registration. The returned provider
    /// snapshot belongs to this pass; a later discovery must not add more work
    /// to an older background refresh that is already serving its own callers.
    private func discoverMachines(force: Bool, updateExisting: Bool) async -> [CmuxTuiSurfaceProvider]? {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud) else { return nil }
        let epoch = accessEpoch
        await teardownInFlight?.value
        while true {
            guard !isRetired, epoch == accessEpoch, !Task.isCancelled else { return nil }
            if let inFlight = discoveryInFlight {
                let discovered = await inFlight.value
                if discoveryInFlight == inFlight { discoveryInFlight = nil }
                guard !isRetired, epoch == accessEpoch, !Task.isCancelled else { return nil }
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
            guard !isRetired, epoch == accessEpoch, !Task.isCancelled else { return nil }
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
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud) else { return nil }
        if let provider = providers[machineID] { return provider }
        let epoch = accessEpoch
        _ = await discoverMachines(force: true, updateExisting: false)
        guard !isRetired, epoch == accessEpoch, !Task.isCancelled else { return nil }
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

    /// Both an explicit delete and fleet reconciliation use the same owned
    /// teardown. Discovery must not await cleanup of an unrelated machine.
    private func unregisterMachine(_ rawID: String) {
        // Callers may hand over a canonicalized (lowercased) id while the
        // registry keys everything by the control plane's own `summary.id`;
        // resolve to the registered key so no table is left behind.
        let id = registeredMachineID(matching: rawID)
        providers[id]?.stop()
        providers[id] = nil
        catalog?.unregister(machine: .cloud(id))
        // Teardowns for one machine run in order: a repeated delete waits for
        // the earlier pass instead of racing it (cancellation would not stop
        // a pass already inside the managers), so a refresh that re-lists the
        // machine awaits the whole chain through the newest task.
        let previousTeardown = machineTeardowns[id]
        machineTeardowns[id] = Task { [links, portForwards] in
            await previousTeardown?.value
            await portForwards?.close(machineID: id)
            await links.disconnect(machineID: id)
        }
    }

    /// The id the registry stores for a machine, matched case-insensitively;
    /// the caller's spelling when nothing is registered under it.
    private func registeredMachineID(matching rawID: String) -> String {
        if providers[rawID] != nil { return rawID }
        let candidates = Set(providers.keys).union(machineTeardowns.keys)
        return candidates.first { $0.caseInsensitiveCompare(rawID) == .orderedSame } ?? rawID
    }

    /// The headless link's local mux socket for a machine, connecting if needed.
    func linkSocketPath(machineID: String) async throws -> (socketPath: String, session: String) {
        let connected = try await links.connected(machineID: machineID)
        return (connected.socketPath, connected.session)
    }

    func privateRoute(machineID: String) async -> String? {
        await links.privateRoute(for: machineID)
    }

    func resolvedPrivateRoute(machineID: String, through hub: CloudWireGuardHub.Ready, fallbackRoute: String, addresses: [String]) async throws -> String {
        try await links.resolvedPrivateRoute(machineID: machineID, through: hub, fallbackRoute: fallbackRoute, addresses: addresses)
    }

    // MARK: - internals

    private func performDiscovery(generation: UInt64, updateExisting: Bool) async -> [CmuxTuiSurfaceProvider]? {
        guard !isRetired, let catalog, let page = await listPage() else { return nil }
        guard !isRetired, generation == refreshGeneration else { return nil }
        let seen = Set(page.vms.map(\.id))
        // Reconcile both stores. A restored catalog can contain a machine for
        // which this process has not created a provider yet.
        let catalogMachineIDs = Set(catalog.machines.keys.compactMap(\.cloudMachineID))
        let staleIDs = Set(providers.keys)
            .union(catalogMachineIDs)
            .union(catalog.pendingRestoredMachineIDs)
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
                let provider = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog, portForwards: portForwards)
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

    func accessDidEnd() async {
        isRetired = true
        accessEpoch &+= 1
        refreshGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        discoveryInFlight?.cancel()
        discoveryInFlight = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        for provider in providers.values { provider.stop() }
        for id in providers.keys { catalog?.unregister(machine: .cloud(id)) }
        providers.removeAll()
        let teardowns = Array(machineTeardowns.values)
        machineTeardowns.removeAll()
        let previous = teardownInFlight
        let teardown = Task { [closeTransports] in
            await previous?.value
            for task in teardowns { await task.value }
            // Signing out drops the tunnel too: the next account enrolls its own.
            await closeTransports()
        }
        teardownInFlight = teardown
        await teardown.value
        if teardownInFlight == teardown { teardownInFlight = nil }
    }
}
