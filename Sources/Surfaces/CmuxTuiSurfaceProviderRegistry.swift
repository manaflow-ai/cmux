import CmuxCloud
import CmuxFoundation
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation

/// Owns one ``CmuxTuiSurfaceProvider`` per cloud machine and keeps the catalog's machine
/// list in step with the control plane: registers a provider for every machine the
/// account can see, unregisters deleted ones, and drives refreshes on the same 45 s
/// cadence the Machines panel uses. Signing out tears everything down.
///
/// Authenticated fleet discovery also prepares the shared terminal carrier, even for
/// an empty fleet. Both follow the Cloud rollout and activation marker; disabling
/// Cloud or signing out stops the carrier without deleting persisted identities.
@MainActor
final class CmuxTuiSurfaceProviderRegistry {
    static let shared = CmuxTuiSurfaceProviderRegistry()

    private var catalog: SurfaceCatalog?
    private var providers: [String: CmuxTuiSurfaceProvider] = [:]
    let links: CloudMachineLinkManager
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
    private var networkObserver: CloudReadRecoveryObserver?
    private var featureFlagObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    /// Whether the periodic fleet read may run right now.
    let isCloudEnabled: @MainActor () -> Bool
    private let allowsBackgroundWork: @MainActor () -> Bool
    private let listPage: @MainActor () async -> VMListPage?
    /// The selected team, whose fleet ``listPage`` reads. New providers are
    /// owned by it; providers owned by another team are retained only while
    /// they back an open surface, and are never pruned by this team's page.
    private let activeTeamID: @MainActor () -> String?
    /// Reads one machine with its owning team (`GET /api/vm/<id>` with that
    /// team's header). Machines of a team other than the selected one are not
    /// on the fleet page, so restored and open panes of that team are found
    /// and kept current through this per-machine read.
    private let loadMachineStatus: @MainActor (_ machineID: String, _ teamID: String) async throws -> VMSummary
    /// Owning teams persisted with restored panes and workspaces, by machine
    /// id. A registered provider's own team takes precedence.
    private var adoptedOwnerTeams: [String: String] = [:]
    /// Whether an account is signed in. Activation prepares the carrier before
    /// the fleet read only for a signed-in account; a signed-out Mac must not
    /// enroll or start a hub from a config a previous account left on disk.
    let hasCloudSession: @MainActor () -> Bool
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
    private(set) var accessEpoch: UInt64 = 0
    /// Create receipts also end at team changes, which preserve the registry's observer epoch.
    private var creationEpoch = UUID()
    /// Machine IDs admitted from a successful create response remain owned by
    /// this registry until a fleet page positively observes them. A stale page
    /// must not prune a receipt that is still converging into discovery.
    private var pendingMachineCreationIDs: Set<String> = []; private var hasCompletedInitialRefresh = false; private var refreshedMachineIDs: Set<SurfaceMachineID> = []
    /// Create receipts that proved a trusted, directly dialable daemon
    /// (snapshot-v2 contract plus a private address). Consumed by the first
    /// `vm.cmux_remote_info` for that machine instead of an attach request.
    private var createdTrustedCarrierIDs: Set<String> = []
    /// Whether account access has ended. Retired registries reject all new Cloud work
    /// until ``start(catalog:)`` reactivates them for the next account.
    var isRetired = true
    /// Same cadence as the Machines panel's list refresh.
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
        activeTeamID: @escaping @MainActor () -> String? = { nil },
        loadMachineStatus: @escaping @MainActor (_ machineID: String, _ teamID: String) async throws -> VMSummary = { _, _ in
            throw CancellationError()
        },
        hasCloudSession: @escaping @MainActor () -> Bool = { true },
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
        self.activeTeamID = activeTeamID
        self.loadMachineStatus = loadMachineStatus
        self.hasCloudSession = hasCloudSession
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
    ///
    /// A receipt that carries the machine's private address registers its
    /// provider directly, exactly as discovery would. New Machine then links
    /// without first re-reading the whole fleet list (`GET /api/vm`, ~0.3 s).
    /// Receipts from older backends without an address keep the old path.
    func recordCreatedMachine(_ summary: VMSummary, scope: UUID?) async {
        guard let scope, scope == creationScope, let catalog else { return }
        // A replay cannot overwrite names or status already accepted by discovery.
        guard catalog.machines[.cloud(summary.id)] == nil, providers[summary.id] == nil else { return }
        pendingMachineCreationIDs.insert(summary.id)
        catalog.admitMachineCreationReceipt(CmuxTuiSurfaceProvider.info(
            from: summary, linkState: .connecting, linkError: nil, stats: nil
        ))
        let addresses = [summary.addressIPv4, summary.addressIPv6].compactMap { $0 }
        guard !addresses.isEmpty, machineTeardowns[registeredMachineID(matching: summary.id)] == nil else { return }
        let generation = refreshGeneration
        let ownerTeamID = activeTeamID()
        await links.setPrivateAddresses(addresses, for: summary.id)
        await links.setOwnerTeam(ownerTeamID, for: summary.id)
        if summary.cmuxTuiContract == Self.trustedCarrierContract {
            await links.markTrustedCarrier(machineID: summary.id)
        }
        // Same fences as discovery: a delete or account change during the
        // await must not receive a provider.
        guard !isRetired, generation == refreshGeneration, scope == creationScope,
              providers[summary.id] == nil else { return }
        let provider = CmuxTuiSurfaceProvider(
            summary: summary, fileAccessTeamScope: AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope,
            ownerTeamID: ownerTeamID, links: links, catalog: catalog,
            portForwards: portForwards, portAccessStore: portAccess
        )
        providers[summary.id] = provider
        catalog.register(provider)
        if summary.cmuxTuiContract == Self.trustedCarrierContract {
            createdTrustedCarrierIDs.insert(summary.id)
        }
        // Start the first link and graph read now, while the caller is still
        // creating its workspace. The open's `ensure_linked` catalog read joins
        // this pass instead of starting its own after the fact.
        Task { [weak provider] in
            _ = await provider?.refreshCurrentGraph(force: false)
        }
    }

    /// The image contract whose daemon serves the trusted private-network
    /// listener with no enrollment (web: FreestyleProvider `cmuxTuiContract`).
    static let trustedCarrierContract = "snapshot-v2"

    /// The private route for a machine this registry just created from a
    /// trusted-carrier receipt, consumed once. Nil means ask the control plane.
    func takeCreatedTrustedCarrierRoute(machineID: String) async -> String? {
        guard createdTrustedCarrierIDs.remove(machineID) != nil,
              !isRetired, isCloudEnabled(), providers[machineID] != nil else { return nil }
        return await links.privateRoute(for: machineID)
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
        createdTrustedCarrierIDs.removeAll()
        refreshGeneration &+= 1
        let epoch = accessEpoch
        // Replacing block observers prevents stale callbacks after a restart.
        if let accessObserver { notificationCenter.removeObserver(accessObserver) }
        accessObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.accessEpoch == epoch else { return }
                self.creationEpoch = UUID()
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
        // The Cloud activation marker can change while the app runs; the poll
        // follows it without a relaunch in both directions.
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = notificationCenter.addObserver(
            forName: RightSidebarBetaFeatureSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPollingToActivationPolicy() }
        }
        networkObserver = CloudReadRecoveryObserver(notificationCenter: notificationCenter) { [weak self] in
            guard let self, !self.isRetired, self.allowsBackgroundWork() else { return }
            _ = await self.refresh(force: false)
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
        if hasCloudSession() { Task { await wireGuardHub?.prepareForCloudUse() } }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // The periodic pass is upkeep: a machine whose link just
                // failed is left alone until its backoff ends.
                await CloudMachineLinkManager.$isBackgroundUpkeep.withValue(true) {
                    await self?.refresh(force: false)
                }
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
                return await self.refreshDiscoveredMachines(discovered, force: force, access: access)
            }
            refreshInFlight = task
            let listed = await task.value
            if refreshInFlight == task { refreshInFlight = nil }
            guard access == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return false }
            return listed
        }
    }

    /// Detail work shares the registry's refresh owner, but is not a prerequisite
    /// for presenting a newly selected team's fleet.
    private func refreshDiscoveredMachines(
        _ discovered: [CmuxTuiSurfaceProvider], force: Bool, access: UInt64
    ) async -> Bool {
        let scope = creationEpoch
        guard access == accessEpoch, !Task.isCancelled else { return false }
        // Another team's machines behind open surfaces are not on the
        // selected team's page; read them one by one with their own
        // team, then refresh them so a revoked membership surfaces as
        // a card, not a freeze.
        await refreshForeignOwnedMachines()
        guard access == accessEpoch, scope == creationEpoch, !Task.isCancelled else { return false }
        let foreign = retainedForeignTeamMachineIDs(activeTeamID: activeTeamID())
            .subtracting(discovered.map(\.machineID))
            .compactMap { providers[$0] }
        let candidates = discovered + foreign
        let activeMachines = (force || !hasCompletedInitialRefresh) ? Set(candidates.map(\.machine)) : (catalog?.projectedMachines ?? []).union(catalog?.pendingRestoredMachineIDs.map(SurfaceMachineID.cloud) ?? []).union(pendingMachineCreationIDs.map(SurfaceMachineID.cloud)).union(Set(discovered.filter { !refreshedMachineIDs.contains($0.machine) || $0.info.linkState != .connected || $0.cloudState?.cursor == nil }.map(\.machine)))
        await withTaskGroup(of: Void.self) { group in
            for provider in candidates where activeMachines.contains(provider.machine) {
                group.addTask { @MainActor in
                    guard access == self.accessEpoch, scope == self.creationEpoch, !Task.isCancelled else { return }
                    let succeeded = await self.refreshProvider(provider, force)
                    if succeeded, access == self.accessEpoch, scope == self.creationEpoch,
                       !Task.isCancelled, provider.isRegisteredInCatalog() {
                        self.refreshedMachineIDs.insert(provider.machine)
                    }
                }
            }
        }
        guard access == accessEpoch, scope == creationEpoch, !Task.isCancelled else { return false }
        hasCompletedInitialRefresh = true
        return true
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

    /// Machines owned by a team other than the selected one. They stay
    /// registered while open surfaces use them but are left out of the
    /// selected team's Cloud sidebar.
    var foreignTeamMachineIDs: Set<String> {
        let active = activeTeamID()
        return Set(providers.compactMap { id, provider in
            guard let owner = provider.ownerTeamID, owner != active else { return nil }
            return id
        })
    }

    /// Another team's machines that still back an open surface (a projected
    /// pane, a restoring pane, or a Cloud workspace bound to the machine).
    private func retainedForeignTeamMachineIDs(activeTeamID active: String?) -> Set<String> {
        guard let catalog else { return [] }
        let projected = catalog.projectedMachines.union(catalog.pendingRestoredMachineIDs.map(SurfaceMachineID.cloud))
        return Set(providers.compactMap { id, provider in
            guard let owner = provider.ownerTeamID, owner != active,
                  !provider.hasLostAccess, projected.contains(.cloud(id)) else { return nil }
            return id
        })
    }

    /// Restored panes of another team whose provider is not registered yet.
    /// The selected team's page must not prune them before their own read.
    private func pendingForeignRestoredMachineIDs(activeTeamID active: String?) -> Set<String> {
        guard let catalog else { return [] }
        return catalog.pendingRestoredMachineIDs.filter { id in
            providers[id] == nil && adoptedOwnerTeams[id].map { $0 != active } == true
        }
    }

    /// The team that owns `machineID`: its provider's team, else the team
    /// persisted with a restored pane or workspace. Nil when unknown.
    func ownerTeamID(forMachineID machineID: String) -> String? {
        providers[machineID]?.ownerTeamID ?? adoptedOwnerTeams[machineID]
    }

    /// Records the owning team persisted with a restored pane or workspace, so
    /// the machine reconnects with that team even when another is selected.
    ///
    /// - Parameters:
    ///   - teamID: The persisted owning team; nil or blank is ignored.
    ///   - machineID: The Cloud machine id.
    func adoptOwnerTeam(_ teamID: String?, forMachineID machineID: String) {
        guard let team = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty,
              WorkspaceCloudVMBinding.normalizedVMID(machineID) != nil, !machineID.hasPrefix("ssh:"),
              providers[machineID] == nil, adoptedOwnerTeams[machineID] != team else { return }
        adoptedOwnerTeams[machineID] = team
        guard !isRetired, team != activeTeamID() else { return }
        Task { [weak self] in _ = await self?.refresh(force: false) }
    }

    /// Registers and updates machines of teams other than the selected one
    /// that back an open or restoring pane, reading each with its own team.
    /// A permanent access loss ends the machine's panes in a visible card.
    private func refreshForeignOwnedMachines() async {
        guard !isRetired, let catalog else { return }
        let active = activeTeamID()
        let needed = Set(catalog.projectedMachines.compactMap(\.cloudMachineID)).union(catalog.pendingRestoredMachineIDs)
        let targets: [(id: String, team: String)] = needed.sorted().compactMap { id in
            if let provider = providers[id] {
                guard let owner = provider.ownerTeamID, owner != active, !provider.hasLostAccess else { return nil }
                return (id, owner)
            }
            guard let team = adoptedOwnerTeams[id], team != active else { return nil }
            return (id, team)
        }
        guard !targets.isEmpty else { return }
        let epoch = accessEpoch
        let generation = refreshGeneration
        for target in targets {
            let summary: VMSummary
            do {
                summary = try await loadMachineStatus(target.id, target.team)
            } catch {
                guard !isRetired, epoch == accessEpoch, generation == refreshGeneration else { return }
                guard CloudMachineAccessLoss(error: error) != nil else { continue }
                if let provider = providers[target.id] {
                    provider.noteAccessLost()
                } else {
                    // No provider ever reached this machine; its restored
                    // panes leave like any machine outside the user's reach.
                    adoptedOwnerTeams[target.id] = nil
                    unregisterMachine(target.id)
                }
                continue
            }
            guard !isRetired, epoch == accessEpoch, generation == refreshGeneration else { return }
            if let provider = providers[target.id] {
                provider.update(summary: summary)
                continue
            }
            guard machineTeardowns[registeredMachineID(matching: target.id)] == nil else { continue }
            await links.setPrivateAddresses([summary.addressIPv4, summary.addressIPv6].compactMap { $0 }, for: summary.id)
            await links.setOwnerTeam(target.team, for: summary.id)
            guard !isRetired, epoch == accessEpoch, generation == refreshGeneration,
                  providers[summary.id] == nil else { return }
            // No selected-team file-access scope: the file explorer stays
            // limited to the selected team's machines.
            let provider = CmuxTuiSurfaceProvider(
                summary: summary, ownerTeamID: target.team, links: links, catalog: catalog,
                portForwards: portForwards, portAccessStore: portAccess
            )
            providers[summary.id] = provider
            catalog.register(provider)
        }
    }

    /// The selected team changed for the same account.
    ///
    /// Cloud surfaces are owned by the team that created them, and every
    /// control-plane call names that team, so open terminals and browsers of
    /// every team keep running. Only discovery moves: in-flight reads and create
    /// receipts of the previous selection are dropped, providers of another
    /// team that no surface uses are retired, and the new team's fleet is read.
    /// The WireGuard hub and its user-scoped enrollment are untouched.
    func teamScopeDidChange() async {
        guard !isRetired else { return }
        creationEpoch = UUID()
        pendingMachineCreationIDs.removeAll(); hasCompletedInitialRefresh = false; refreshedMachineIDs.removeAll()
        createdTrustedCarrierIDs.removeAll()
        refreshGeneration &+= 1
        discoveryInFlight?.cancel()
        discoveryInFlight = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        let active = activeTeamID()
        let retained = retainedForeignTeamMachineIDs(activeTeamID: active)
        for (id, provider) in providers where provider.ownerTeamID != active && !retained.contains(id) {
            unregisterMachine(id)
        }
        let access = accessEpoch
        let scope = creationEpoch
        guard let discovered = await discoverMachines(force: true, updateExisting: true),
              access == accessEpoch, scope == creationEpoch, !Task.isCancelled else { return }
        // Readiness means the selected team's fleet has been reconciled. A slow
        // link, workspace snapshot, or foreign-team read must not hold the
        // sidebar behind the detail refresh. Retain the task under the normal
        // refresh owner so a later team change, sign-out, or feature suspension
        // cancels it, and ordinary refresh callers still join it.
        if refreshInFlight == nil {
            refreshInFlight = Task { [weak self] in
                guard let self, scope == self.creationEpoch else { return false }
                defer {
                    // A cancelled older pass must not clear its replacement.
                    if !Task.isCancelled, access == self.accessEpoch, scope == self.creationEpoch {
                        self.refreshInFlight = nil
                    }
                }
                return await self.refreshDiscoveredMachines(discovered, force: true, access: access)
            }
        }
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
        if providers[machineID] == nil, adoptedOwnerTeams[machineID] != nil {
            await refreshForeignOwnedMachines()
            guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
        }
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

    /// Stops machine-bound transports while retaining the provider and its graph.
    func machineBecameInactive(_ rawID: String, status: String = "paused") async {
        let id = registeredMachineID(matching: rawID)
        await links.recordLocalMachineStatus(status, for: id)
        guard let provider = providers[id] else { return }
        provider.markInactive(status: status)
        scheduleTransportTeardown(rawID, provider: provider)
    }

    /// Deletion and discovery share ordered teardown without waiting for unrelated machines.
    private func unregisterMachine(_ rawID: String, stopReason: CloudTuiManualMirrorStopReason = .accessLost) {
        // Match the registered casing so every ownership table is removed.
        let id = registeredMachineID(matching: rawID)
        pendingMachineCreationIDs.remove(id); refreshedMachineIDs.remove(.cloud(id))
        createdTrustedCarrierIDs.remove(id)
        let provider = providers.removeValue(forKey: id)
        // The machine left the owning team's list (deleted, or the user lost
        // access). Open panes keep the access-lost card, never a frozen frame.
        provider?.suspendForFeatureFlag(stopReason: stopReason)
        catalog?.removeCloudMachine(.cloud(id))
        // Teardowns for one machine run in order: a repeated delete waits for
        // the earlier pass instead of racing it (cancellation would not stop
        // a pass already inside the managers), so a refresh that re-lists the
        // machine awaits the whole chain through the newest task.
        scheduleTeardown(id, provider: provider, retireProvider: true, stopReason: stopReason)
    }

    private func scheduleTransportTeardown(_ rawID: String, provider: CmuxTuiSurfaceProvider) {
        provider.stopTransportResources()
        scheduleTeardown(rawID, provider: provider, retireProvider: false)
    }

    private func scheduleTeardown(_ rawID: String, provider: CmuxTuiSurfaceProvider?, retireProvider: Bool, stopReason: CloudTuiManualMirrorStopReason = .cloudUnavailable) {
        let id = registeredMachineID(matching: rawID)
        let previousTeardown = machineTeardowns[id]
        machineTeardowns[id] = Task { [links, portForwards, portAccess] in
            await previousTeardown?.value
            if let provider {
                if retireProvider { await provider.stop(stopReason: stopReason) }
                else { await portAccess.remove(machineID: id) }
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
        let discoveryStartedAt = Date()
        // The page belongs to the team selected when the read started. The
        // client cancels the read if the selection changes before it returns.
        let pageTeamID = activeTeamID()
        guard !isRetired, let catalog, let page = await listPage() else { return nil }
        guard !isRetired, generation == refreshGeneration, isCloudEnabled(), !Task.isCancelled,
              pageTeamID == activeTeamID() else { return nil }
        if allowsBackgroundWork() { await wireGuardHub?.prepareForCloudUse() }
        guard !isRetired, generation == refreshGeneration, isCloudEnabled(), !Task.isCancelled else { return nil }
        let seen = Set(page.vms.map(\.id))
        // Session restore can precede a successful fleet read. Rehydrate a
        // provider from persisted machine metadata so a restored browser can
        // reconnect instead of being pruned when the first page is empty.
        await registerPendingRestoredMachines(pageTeamID: pageTeamID, generation: generation)
        // This page is the authoritative positive observation for any receipt
        // it contains. Once observed, normal stale pruning may own that ID.
        pendingMachineCreationIDs.subtract(seen)
        // Reconcile both stores. A restored catalog can contain a machine for
        // which this process has not created a provider yet.
        let catalogMachineIDs = Set(catalog.machines.keys.compactMap(\.cloudMachineID))
        // Another team's machines are not on this page. They stay while an
        // open surface uses them; that team's own page or an access-denied
        // answer is what retires them, never this team's list.
        let retainedForeignIDs = retainedForeignTeamMachineIDs(activeTeamID: pageTeamID)
            .union(pendingForeignRestoredMachineIDs(activeTeamID: pageTeamID))
        let staleIDs = Set(providers.keys)
            .union(catalogMachineIDs)
            .union(catalog.pendingRestoredMachineIDs)
            .subtracting(pendingMachineCreationIDs)
            .subtracting(seen)
            .subtracting(retainedForeignIDs)
            // A restored projection is itself an ownership claim. Keep its
            // machine registered until its provider resolves the projection
            // or reports access loss, even when discovery returns a partial
            // page that omits the machine.
            .subtracting(catalog.pendingRestoredMachineIDs)
        for id in staleIDs {
            unregisterMachine(id)
        }
        await links.retainAddresses(machineIDs: seen.union(retainedForeignIDs))
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
            let statusAccepted = await links.setMachineStatus(summary.status, for: registeredID, observedAt: discoveryStartedAt)
            // A delete that ran while that await was suspended bumped the
            // generation; creating a provider now would hand its link and
            // forwards to the teardown that delete scheduled.
            guard generation == refreshGeneration else { return nil }
            if let provider = providers[summary.id] {
                if statusAccepted {
                    provider.update(summary: summary)
                    if CloudMachineLinkManager.isAsleepStatus(summary.status) {
                        scheduleTransportTeardown(summary.id, provider: provider)
                    }
                }
            } else {
                await links.setOwnerTeam(pageTeamID, for: summary.id)
                guard generation == refreshGeneration else { return nil }
                let provider = CmuxTuiSurfaceProvider(
                    summary: summary, fileAccessTeamScope: AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope,
                    ownerTeamID: pageTeamID, links: links, catalog: catalog,
                    portForwards: portForwards, portAccessStore: portAccess
                )
                providers[summary.id] = provider
                catalog.register(provider)
            }
        }
        return page.vms.compactMap { providers[$0.id] }
    }

    private func registerPendingRestoredMachines(pageTeamID: String?, generation: UInt64) async {
        guard let catalog else { return }
        for machineID in catalog.pendingRestoredMachineIDs where providers[machineID] == nil {
            guard let info = catalog.machineInfo(for: .cloud(machineID)),
                  let ownerTeamID = adoptedOwnerTeams[machineID] ?? pageTeamID,
                  !ownerTeamID.isEmpty,
                  !isRetired, generation == refreshGeneration,
                  isCloudEnabled(), !Task.isCancelled else { continue }
            await links.setPrivateAddresses([info.privateAddress].compactMap { $0 }, for: machineID)
            await links.setOwnerTeam(ownerTeamID, for: machineID)
            guard !isRetired, generation == refreshGeneration, providers[machineID] == nil else { continue }
            let summary = VMSummary(
                id: machineID, provider: "freestyle", status: info.status,
                image: info.image ?? "", createdAt: 0,
                kind: info.hasDesktop ? .desktop : .base,
                capabilities: VMCapabilities(
                    snapshot: false, restore: false, fork: false,
                    exec: true, stats: true, ports: true,
                    desktop: info.hasDesktop, sizing: false, persistentHome: true
                ), displayName: info.name, addressIPv4: info.privateAddress
            )
            let provider = CmuxTuiSurfaceProvider(
                summary: summary,
                fileAccessTeamScope: AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope,
                ownerTeamID: ownerTeamID, links: links, catalog: catalog,
                portForwards: portForwards, portAccessStore: portAccess
            )
            providers[machineID] = provider
            catalog.register(provider)
            Task { [weak provider] in _ = await provider?.refreshCurrentGraph(force: true) }
        }
    }

    /// Notification-driven teardown. Ignored when it belongs to a registry
    /// generation an intervening ``start(catalog:)`` has already replaced.
    func accessDidEnd(epoch: UInt64) async {
        guard epoch == accessEpoch else { return }
        await accessDidEnd()
    }

    /// Synchronous publication fence shared by team switching and full teardown.
    private func invalidateAccess() {
        networkObserver = nil
        adoptedOwnerTeams.removeAll()
        isRetired = true
        accessEpoch &+= 1
        creationEpoch = UUID()
        pendingMachineCreationIDs.removeAll(); hasCompletedInitialRefresh = false; refreshedMachineIDs.removeAll()
        createdTrustedCarrierIDs.removeAll()
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
        for provider in providers.values { provider.suspendForFeatureFlag(stopReason: .signedOut) }
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
