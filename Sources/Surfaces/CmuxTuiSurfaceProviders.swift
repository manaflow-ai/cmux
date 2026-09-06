import CmuxFoundation
import Foundation

/// Owns one ``CmuxTuiSurfaceProvider`` per cloud machine and keeps the catalog's machine
/// list in step with the control plane: registers a provider for every machine the
/// account can see, unregisters deleted ones, and drives refreshes on the same 45 s
/// cadence the Machines panel uses. Signing out tears everything down.
@MainActor
final class CmuxTuiSurfaceProviderRegistry {
    static let shared = CmuxTuiSurfaceProviderRegistry()

    private var catalog: SurfaceCatalog?
    private var providers: [String: CmuxTuiSurfaceProvider] = [:]
    private let links: CloudMachineLinkManager
    /// The app's one WireGuard hub for private-network machines; nil when no cmux-tui
    /// client is bundled (then no link can be made at all).
    let wireGuardHub: CloudWireGuardHub?
    private var pollTask: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var refreshInFlight: Task<Bool, Never>?
    /// A forced refresh waits for an existing pass instead of starting a second
    /// fleet read. This prevents an older page from unregistering a machine that
    /// a newer page just added.
    private var refreshGeneration: UInt64 = 0
    /// Same cadence as the Machines panel's list refresh.
    private let pollInterval: Duration = .seconds(45)

    init(links: CloudMachineLinkManager, wireGuardHub: CloudWireGuardHub?) {
        self.links = links
        self.wireGuardHub = wireGuardHub
    }

    /// The production registry: one hub over the bundled client, shared by every link.
    convenience init() {
        let hub = CloudTuiClientPaths.clientURL().map { CloudWireGuardHub.production(clientURL: $0) }
        self.init(links: CloudMachineLinkManager(hub: hub), wireGuardHub: hub)
    }

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
        // Block observers are retained by NotificationCenter: drop the previous
        // tokens so a re-start never leaves stale callbacks registered.
        if let accessObserver { NotificationCenter.default.removeObserver(accessObserver) }
        accessObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.accessDidEnd() }
        }
        // A Ghostty config reload can change the resolved theme; re-push it so remote
        // panes keep matching the local ones (connect-time push covers new links).
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.links.pushHostThemeToConnectedLinks() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                // The poll interval is the intended behavior (the list is not push-driven),
                // not a synchronization substitute.
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(45))
            }
        }
    }

    /// Re-reads the machine list and refreshes every provider (links, snapshots, ports).
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        while true {
            if let inFlight = refreshInFlight {
                let listed = await inFlight.value
                if refreshInFlight == inFlight {
                    refreshInFlight = nil
                }
                if !force { return listed }
                continue
            }

            refreshGeneration &+= 1
            let generation = refreshGeneration
            let task = Task<Bool, Never> { [weak self] in
                guard let self else { return false }
                return await self.performRefresh(force: force, generation: generation)
            }
            refreshInFlight = task
            let listed = await task.value
            if refreshGeneration == generation {
                refreshInFlight = nil
            }
            return listed
        }
    }

    func provider(machineID: String) -> CmuxTuiSurfaceProvider? {
        providers[machineID]
    }

    /// The provider for a machine that may have been created a moment ago (`cmux vm new`
    /// opens its terminal right after `POST /api/vm` returns): when the registry has not
    /// listed it yet, re-read the fleet once instead of failing with "no provider".
    func providerRefreshingIfMissing(machineID: String) async -> CmuxTuiSurfaceProvider? {
        if let provider = providers[machineID] { return provider }
        await refresh(force: true)
        return providers[machineID]
    }

    func machineWasDeleted(_ id: String) {
        providers[id]?.stop()
        providers[id] = nil
        catalog?.unregister(machine: .cloud(id))
        Task { await links.disconnect(machineID: id) }
    }

    /// The headless link's local mux socket for a machine, connecting if needed.
    func linkSocketPath(machineID: String) async throws -> (socketPath: String, session: String) {
        let connected = try await links.connected(machineID: machineID)
        return (connected.socketPath, connected.session)
    }

    func privateRoute(machineID: String) async -> String? {
        await links.privateRoute(for: machineID)
    }

    // MARK: - internals

    private func performRefresh(force: Bool, generation: UInt64) async -> Bool {
        guard let catalog, let client = VMClient.shared else { return false }
        guard let page = try? await client.listPage() else { return false }
        guard generation == refreshGeneration else { return false }
        let seen = Set(page.vms.map(\.id))
        if seen.isEmpty {
            await wireGuardHub?.releasePrewarm()
        } else if let wireGuardHub {
            // Start one shared hub before per-machine refreshes race to create links.
            // A transient DNS/handshake failure is retried inside `prewarm`; retaining
            // its claim also lets the actor restart an unexpected child exit immediately.
            _ = try? await wireGuardHub.prewarm()
        }
        // Reconcile both stores. A restored catalog can contain a machine for
        // which this process has not created a provider yet.
        let catalogMachineIDs = Set(catalog.machines.keys.compactMap(\.cloudMachineID))
        let staleIDs = Set(providers.keys)
            .union(catalogMachineIDs)
            .union(catalog.pendingRestoredMachineIDs)
            .subtracting(seen)
        for id in staleIDs {
            providers[id]?.stop()
            providers[id] = nil
            catalog.unregister(machine: .cloud(id))
        }
        await links.retain(machineIDs: seen)
        guard generation == refreshGeneration else { return false }
        for summary in page.vms {
            await links.setPrivateAddress(summary.preferredPrivateAddress, for: summary.id)
            if let provider = providers[summary.id] {
                provider.update(summary: summary)
            } else {
                let provider = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog)
                providers[summary.id] = provider
                catalog.register(provider)
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in providers.values {
                group.addTask { @MainActor in await provider.refresh(force: force) }
            }
        }
        return true
    }

    func accessDidEnd() async {
        for provider in providers.values { provider.stop() }
        for id in providers.keys { catalog?.unregister(machine: .cloud(id)) }
        providers.removeAll()
        await links.disconnectAll()
        // Signing out drops the tunnel too: the next account enrolls its own.
        await wireGuardHub?.stop()
    }
}

/// One cloud machine's resources: its cmux-tui terminals (over the headless link), its
/// noVNC screen, and its forwarded ports. Terminals live in the machine's cmux-tui
/// session, so a local pane closing never touches them (`projectionDidEnd` is a no-op).
@MainActor
final class CmuxTuiSurfaceProvider: SurfaceProvider {
    enum ProviderError: Error, LocalizedError {
        case notSignedIn
        case machineAsleep(String)
        case noWorkspaceOnMachine(String)
        case terminalNotCreated(String)
        case invalidSnapshot(String)
        case snapshotOnly(String)
        case stateUnavailable(String)
        case badURL(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Cloud VM access requires sign-in. Run `cmux auth login`, then retry."
            case .machineAsleep(let id):
                return "\(id) is asleep; open it (`cmux vm shell \(id)`) to wake it before listing its terminals."
            case .noWorkspaceOnMachine(let id):
                return "\(id) has no cmux-tui workspace yet."
            case .terminalNotCreated(let detail):
                return "cmux-tui did not report the new terminal: \(detail)"
            case .invalidSnapshot(let id):
                return "cmux-tui returned an unversioned or malformed session snapshot for \(id)."
            case .snapshotOnly(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.snapshotOnly",
                        defaultValue: "%@ uses an older cmux-tui protocol. Refresh it to enable live sync and rename operations."
                    ),
                    id
                )
            case .stateUnavailable(let id):
                return String(
                    format: String(
                        localized: "cloudTree.error.renameTerminalUnavailable",
                        defaultValue: "The current state for %@ is unavailable. Refresh and retry before renaming."
                    ),
                    id
                )
            case .badURL(let url):
                return "The control plane returned an unusable URL: \(url)"
            }
        }
    }

    let machineID: String
    var machine: SurfaceMachineID { .cloud(machineID) }
    private(set) var info: SurfaceMachineInfo

    private var summary: VMSummary
    let links: CloudMachineLinkManager
    unowned let catalog: SurfaceCatalog
    /// Invalidates suspended work when this provider is stopped or replaced.
    private var lifecycleGeneration: UInt64 = 0
    /// Invalidates an older refresh before it can publish over a newer one.
    private var refreshGeneration: UInt64 = 0
    /// The only installed daemon graph for this machine. The catalog receives the
    /// same immutable value with its derived rows in one transaction.
    private(set) var cloudState: CloudVMState?
    /// Local ordering fence for concurrent snapshot commands and the event
    /// reader. Remote generations are opaque, so a response from an older
    /// request must not replace a generation installed later in the same turn.
    private var cloudStateInstallVersion: UInt64 = 0
    /// Generations accepted by this provider instance. Generation identifiers
    /// are opaque, but a repeated identifier after a reconnect is still proof
    /// that a response came from an older link. Keeping this set prevents a
    /// delayed old snapshot from time-travelling the canonical graph.
    private var acceptedCloudGenerations: Set<String> = []
    /// A failed event feed is a transport warning, separate from the freshness of the last
    /// accepted snapshot. Agents can read the exact graph and the warning in one export.
    private var eventsFeedWarning: String?
    private var stateRecoveryRefreshTask: Task<Void, Never>?
    private var stateRecoveryRefreshQueued = false
    private var stateRecoveryCount = 0
    private static let stateRecoveryLimit = 5
    private var changeWatcher: Task<Void, Never>?
    /// Identity of the link owned by `changeWatcher`. A provider can replace a
    /// dead link during refresh; the old stream must not clear or restart the
    /// watcher for the new link.
    private var watchedLink: CloudMachineLink?
    private var changeWatcherID: UUID?
    private var scheduledRefresh: Task<Void, Never>?
    private var portsCache: (ports: [Int], at: Date)?
    private let portsTTL: TimeInterval = 30
    /// Panels this provider created (or replaced) in this process. A projection whose
    /// panel is not here came back from a restored session as a placeholder shell.
    var materializedPanels: Set<UUID> = []
    /// Native cloud terminals own a manual attachment separate from their
    /// catalog projection. The provider retains it for the life of the pane.
    var manualMirrorSessions: [UUID: CloudTuiManualMirrorSession] = [:]
    /// Numeric cmux-tui surface ids are process-local. Re-read the legacy tree
    /// when the link socket generation changes or an attachment disconnects,
    /// then reuse the result for the rest of that socket generation.
    private var manualMirrorSurfaceIDsSocketPath: String?
    /// Terminal → tab from the last snapshot, so an exited terminal (whose own selector
    /// no longer resolves in cmux-tui) can still be closed through its tab.
    private var tabByTerminal: [String: String] = [:]
    /// Coalesces concurrent first opens of a zero-view terminal. `terminal.project` is a
    /// mutation, so two local panes racing on the same pool row must share one remote view.
    // Internal so the manual-mirror extension can share the provider-owned task map.
    var remoteTerminalProjectionTasks: [String: Task<Void, Error>] = [:]
    /// User labels from the last authoritative snapshot, used to compensate a
    /// multi-view rename if a later tab mutation fails.
    private var tabNameByID: [String: String] = [:]
    /// A mutation response is a read-your-write receipt, but the event stream or
    /// the next snapshot can lag it. Keep the exact created row and placement
    /// until an accepted graph reaches that receipt. This is a transient view
    /// overlay, never a second remote-state store.
    private struct PendingRemoteCreation {
        var resource: SurfaceResource
        var receipt: CloudVMCursor?
        let tabID: String?
    }
    private var pendingRemoteCreations: [SurfaceResourceID: PendingRemoteCreation] = [:]
    /// Rename receipts are transient read-your-write fences. They are keyed by
    /// daemon identity, not by a local title or projection, because one remote
    /// tab can be shown in several windows. The canonical graph remains the
    /// only source of remote values.
    private enum PendingRemoteRenameKey: Hashable {
        case workspace(String)
        case tab(String)
    }

    private struct PendingRemoteRename {
        var name: String
        var receipt: CloudVMCursor
    }

    private var pendingRemoteRenames: [PendingRemoteRenameKey: PendingRemoteRename] = [:]

    init(
        summary: VMSummary,
        links: CloudMachineLinkManager,
        catalog: SurfaceCatalog
    ) {
        machineID = summary.id
        self.summary = summary
        self.links = links
        self.catalog = catalog
        info = Self.info(from: summary, linkState: summary.status == "running" ? .connecting : .asleep, linkError: nil, stats: nil)
    }

    var isAwake: Bool { summary.status == "running" }

    /// Port rows are openable only when the machine advertises a preview
    /// capability or has the private route used by Freestyle.
    var capabilities: VMCapabilities { summary.capabilities }
    var supportsPortPreviews: Bool {
        capabilities.ports || summary.preferredPrivateAddress != nil
    }

    func update(summary: VMSummary) {
        guard isRegisteredInCatalog() else { return }
        refreshGeneration &+= 1
        self.summary = summary
        if !supportsPortPreviews {
            portsCache = nil
        }
        let shouldMarkStale = summary.status != "running" && cloudState != nil
        let linkState: SurfaceLinkState = shouldMarkStale ? .asleep : info.linkState
        let linkError: String? = shouldMarkStale ? nil : info.linkError
        info = Self.info(
            from: summary,
            linkState: linkState,
            linkError: linkError,
            stats: nil,
            remoteWorkspaces: info.remoteWorkspaces
        )
        if shouldMarkStale {
            catalog.markCloudStateStale(on: machine, reason: "machine_\(summary.status)", info: info)
        } else {
            catalog.updateMachine(info, from: self)
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        changeWatcher?.cancel()
        changeWatcher = nil
        watchedLink = nil
        changeWatcherID = nil
        scheduledRefresh?.cancel()
        scheduledRefresh = nil
        stateRecoveryRefreshTask?.cancel()
        stateRecoveryRefreshTask = nil
        stateRecoveryRefreshQueued = false
        stateRecoveryCount = 0
        eventsFeedWarning = nil
        for session in manualMirrorSessions.values { session.stop() }
        manualMirrorSessions.removeAll()
        manualMirrorSurfaceIDsSocketPath = nil
        for task in remoteTerminalProjectionTasks.values { task.cancel() }
        remoteTerminalProjectionTasks.removeAll()
        pendingRemoteCreations.removeAll()
        pendingRemoteRenames.removeAll()
        acceptedCloudGenerations.removeAll()
    }

    /// Whether this provider is still registered for its machine. Suspended
    /// network work must not write through a replacement provider.
    func isRegisteredInCatalog() -> Bool {
        guard let current = catalog.provider(for: machine) else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(self)
    }

    func isCurrentLifecycleGeneration(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
    }

    private func isCurrentRefresh(lifecycle: UInt64, refresh: UInt64) -> Bool {
        lifecycleGeneration == lifecycle
            && refreshGeneration == refresh
            && isRegisteredInCatalog()
    }

    // MARK: - SurfaceProvider

    func refresh() async {
        await refresh(force: false)
    }

    /// Re-syncs from the machine. A sleeping machine is never woken to be listed: it keeps
    /// its screen (opening it wakes the machine) and nothing else.
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        let lifecycle = lifecycleGeneration
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else { return false }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        let machine = self.machine
        let requestVersion = cloudStateInstallVersion
        // The backend's explicit kind is authoritative. Inferring a desktop from
        // an image name would misclassify the shared shell-only Freestyle image.
        let hasDesktop = summary.resolvedKind.hasDesktop
        let previousResources = catalog.snapshot.resources(on: machine)
        let preservedNonPortResources = previousResources.filter { !$0.id.isForwardedPort }
        let vmClient = VMClient.shared
        let privateAddress = summary.preferredPrivateAddress
        var scannedPorts: [Int]?
        if !supportsPortPreviews {
            scannedPorts = []
        } else {
            // Keep the last private-link scan while this refresh reconnects. A new
            // scan runs through cmux-tui after the link is ready. Routine catalog
            // refresh must never use provider exec or the web control plane.
            scannedPorts = portsCache?.ports
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        var currentPorts = scannedPorts ?? portsCache?.ports ?? []
        guard isAwake, let client = vmClient else {
            tabByTerminal = [:]
            let remoteWorkspaces = remoteWorkspaces(for: cloudState)
            let linkState: SurfaceLinkState = isAwake ? .unavailable : .asleep
            let linkError: String? = isAwake ? "cloud_api_unavailable" : nil
            info = Self.info(from: summary, linkState: linkState, linkError: linkError, stats: nil)
            info.remoteWorkspaces = remoteWorkspaces
            let resources: [SurfaceResource]
            if let cloudState {
                let parsed = CmuxTuiSnapshotParser.mergingDisplays(
                    pool: hasDesktop ? [desktopDisplayResource()] : [],
                    parsed: CmuxTuiSnapshotParser.resources(from: cloudState)
                ) + Self.portResources(
                    machine: machine,
                    scannedPorts: scannedPorts,
                    previousResources: previousResources,
                    privateAddress: summary.preferredPrivateAddress
                )
                resources = resourcesWithPendingCreations(parsed, state: cloudState)
            } else {
                var fallback = hasDesktop ? [desktopDisplayResource()] : []
                fallback.append(contentsOf: Self.portResources(
                    machine: machine,
                    scannedPorts: scannedPorts,
                    previousResources: previousResources,
                    privateAddress: summary.preferredPrivateAddress
                ))
                appendMissingResources(preservedNonPortResources, to: &fallback)
                resources = resourcesWithPendingCreations(fallback, state: nil)
            }
            catalog.replaceUnavailableCloudState(
                on: machine,
                resources: resources,
                info: info,
                pendingWrites: pendingMutationMetadata()
            )
            return false
        }
        // Publish the display before the terminal link is ready: a slow or hanging
        // connect must not leave the desktop unopenable. Its private URL still waits
        // for the browser Network Extension when the user opens it.
        if hasDesktop, catalog.snapshot.resources(on: machine).isEmpty {
            catalog.replaceResources([desktopDisplayResource()], on: machine, info: info, from: self)
        }
        async let stats = try? client.stats(id: machineID)
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        // A decoded snapshot is not automatically an authorization boundary. It
        // can lose an install race, or be older than the graph already accepted.
        // Callers must use only a graph established by this refresh as mutation
        // evidence, never the retained stale graph.
        var snapshotEstablishedCurrentGraph = false
        do {
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            let connected = try await links.connected(machineID: machineID)
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            // Listening ports come from the machine itself over the private link: a
            // failed probe keeps the cached rows, a successful scan is authoritative.
            if let refreshedPorts = await ports(
                link: link,
                socketPath: connected.socketPath,
                force: force,
                generation: generation,
                privateAddress: privateAddress
            ) {
                guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
                scannedPorts = refreshedPorts
                currentPorts = refreshedPorts
            }
            watchChanges(link: link, generation: lifecycle)
            let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let incoming = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine)
            else { throw ProviderError.invalidSnapshot(machineID) }
            let installed = installSnapshotIfNewer(incoming, requestVersion: requestVersion)
            // Equal cursors are a valid no-op refresh only when the accepted
            // graph is byte-for-byte equivalent. A cursor alone is not proof
            // that a malformed or misconfigured daemon returned the same graph.
            // A newer event can also win the race while this snapshot is in
            // flight; the final install-version check below covers that case.
            snapshotEstablishedCurrentGraph = installed
            // Derive compatibility maps from the graph that won the install race.
            // The event reader may have advanced it while this snapshot was in flight.
            let authoritative = cloudState?.snapshotObject() ?? object
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: authoritative)
            tabNameByID = CmuxTuiSnapshotParser.tabNames(fromSnapshot: authoritative)
            if let cursor = cloudState?.cursor {
                await link.setEventsCursor(cursor)
                // This is deliberately adjacent to the mode check. A legacy
                // snapshot suspends the reader; the first accepted versioned
                // snapshot must reopen it on the same refresh, not wait for a
                // later reconnect or optional lookup.
                let subscriptionResumed = await link.resumeEventsSubscription(from: cursor)
                if CloudVMEventFeedRecoveryDecision.shouldClearWarning(
                    snapshotCursor: cursor,
                    subscriptionResumed: subscriptionResumed
                ) {
                    eventsFeedWarning = nil
                }
            } else {
                // Keep legacy VMs readable, but do not consume an event stream
                // whose items cannot be ordered against the installed snapshot.
                await link.suspendEventsSubscription()
            }
            let needsSurfaceIDRefresh = !manualMirrorSessions.isEmpty
                && (manualMirrorSurfaceIDsSocketPath != connected.socketPath
                    || manualMirrorSessions.values.contains { $0.phase == .disconnected })
            var reconnectableSessionIDs = Set<ObjectIdentifier>(
                manualMirrorSessions.values.map { ObjectIdentifier($0) }
            )
            if needsSurfaceIDRefresh {
                let sessions = Array(manualMirrorSessions.values)
                let resolutions = await resolveManualMirrorSessions(
                    sessions,
                    socketPath: connected.socketPath,
                    link: link
                )
                guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
                var allSurfaceIDsResolved = true
                for session in sessions {
                    switch resolutions[session.terminalID] {
                    case let .resolved(surfaceID):
                        session.updateRemoteSurfaceID(surfaceID)
                        reconnectableSessionIDs.insert(ObjectIdentifier(session))
                    case .none, .noPlacement, .unsupported, .failed:
                        session.markSurfaceResolutionUnavailable()
                        reconnectableSessionIDs.remove(ObjectIdentifier(session))
                        allSurfaceIDsResolved = false
                    }
                }
                if allSurfaceIDsResolved {
                    manualMirrorSurfaceIDsSocketPath = connected.socketPath
                }
            }
            for session in manualMirrorSessions.values
            where reconnectableSessionIDs.contains(ObjectIdentifier(session)) {
                session.reconnect(socketPath: connected.socketPath)
            }
        } catch {
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            let status = await links.status(machineID: machineID)
            linkState = eventsFeedWarning == nil ? (status?.state ?? .error) : .error
            let text = eventsFeedWarning ?? status?.error ?? CloudMachineLink.errorText(error)
            linkError = text
            #if DEBUG
            cmuxDebugLog("cloud.provider.refreshFailed machine=\(machineID) state=\(linkState) error=\(String(reflecting: error))")
            #endif
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        if let eventsFeedWarning {
            linkState = .error
            linkError = eventsFeedWarning
        }
        let remoteWorkspaces = cloudState.map(Self.remoteWorkspaces)
        info = Self.info(
            from: summary,
            linkState: linkState,
            linkError: linkError,
            stats: await stats,
            remoteWorkspaces: remoteWorkspaces
        )
        if let cloudState {
            // A successful read or an event install proves the retained graph is
            // current. A failed or stale read keeps the graph for diagnosis but
            // marks it stale, so agents can see it without treating it as truth.
            let stateAdvancedDuringRead = cloudStateInstallVersion != requestVersion
            snapshotEstablishedCurrentGraph = snapshotEstablishedCurrentGraph || stateAdvancedDuringRead
            // A successful snapshot is current even when the subscription is degraded. The
            // warning stays in machine info, so agents see both the exact last read and the
            // missing live-feed guarantee instead of an apparently permanent stale graph.
            let observation: CloudVMStateObservation = snapshotEstablishedCurrentGraph
                ? .current
                : .stale(reason: eventsFeedWarning ?? info.linkError ?? info.linkState.rawValue)
            publish(
                cloudState,
                ports: currentPorts,
                reconcileTitles: snapshotEstablishedCurrentGraph,
                observation: observation
            )
        } else {
            let resources = resourcesWithPendingCreations(
                hasDesktop ? [desktopDisplayResource()] : [],
                state: nil
            )
            var fallback = resources
            if scannedPorts == nil {
                appendMissingResources(preservedNonPortResources, to: &fallback)
            }
            let accepted = catalog.replaceResources(
                catalog.preservingConcurrentPortResources(fallback, on: machine, since: previousResources),
                on: machine,
                info: info,
                from: self
            )
            guard accepted else { return false }
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
        reprojectRestoredPanes(generation: lifecycle)
        return snapshotEstablishedCurrentGraph
    }

    @discardableResult
    private func installSnapshotIfNewer(_ incoming: CloudVMState, requestVersion: UInt64? = nil) -> Bool {
        guard acceptsIncomingGeneration(incoming.cursor) else {
            #if DEBUG
            cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=old-generation")
            #endif
            return false
        }
        // A snapshot with the exact installed cursor is a valid no-op only when
        // its graph and every pending receipt agree. This is important after a
        // rename: a delayed equal-cursor predecessor must not look current.
        if let current = cloudState, current.cursor == incoming.cursor {
            guard current == incoming, incomingPassesPendingRenameFence(incoming) else {
                #if DEBUG
                cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=equal-cursor-conflict")
                #endif
                return false
            }
            retirePendingRemoteRenames(observed: incoming)
            return true
        }
        switch CloudVMStateSyncDecision.forSnapshot(
            incoming: incoming.cursor,
            current: cloudState?.cursor
        ) {
        case .ignoreStale:
            return false
        case .installSnapshot:
            if let current = cloudState,
               let currentCursor = current.cursor,
               let incomingCursor = incoming.cursor,
               currentCursor.generation != incomingCursor.generation,
               let requestVersion,
                requestVersion != cloudStateInstallVersion {
                return false
            }
            guard incomingPassesPendingRenameFence(incoming) else {
                #if DEBUG
                cmuxDebugLog("cloud.state.snapshotIgnored machine=\(machineID) reason=pending-rename-fence")
                #endif
                return false
            }
            cloudState = incoming
            cloudStateInstallVersion &+= 1
            if let generation = incoming.cursor?.generation {
                acceptedCloudGenerations.insert(generation)
            }
            retirePendingRemoteRenames(observed: incoming)
            return true
        case .fetchSnapshot:
            return false
        }
    }

    /// A daemon generation is opaque, but this provider remembers every
    /// generation accepted by the current link lifetime. A response carrying a
    /// previously seen generation after another generation was accepted is an
    /// old-link response and cannot replace the graph.
    private func acceptsIncomingGeneration(_ cursor: CloudVMCursor?) -> Bool {
        guard let cursor else { return true }
        switch CloudVMGenerationAcceptanceDecision.resolve(
            incoming: cursor.generation,
            current: cloudState?.cursor?.generation,
            accepted: acceptedCloudGenerations
        ) {
        case .accept: return true
        case .rejectStale: return false
        }
    }

    /// Checks all in-flight rename receipts before a graph becomes visible.
    /// Rejecting the whole graph keeps unrelated rows from being published with
    /// a target row known to be stale at the same cursor.
    private func incomingPassesPendingRenameFence(_ incoming: CloudVMState) -> Bool {
        for (key, pending) in pendingRemoteRenames {
            let targetMatches: Bool
            switch key {
            case .workspace(let id):
                targetMatches = incoming.lookupIndex.workspace(id: id)?.name == pending.name
            case .tab(let id):
                targetMatches = (incoming.lookupIndex.tab(id: id)?.name ?? "") == pending.name
            }
            switch CloudVMRemoteMutationReceiptDecision.resolve(
                receipt: pending.receipt,
                incoming: incoming.cursor,
                targetMatches: targetMatches
            ) {
            case .accept:
                continue
            case .rejectStale, .rejectConflict:
                return false
            }
        }
        return true
    }

    /// Retires receipts only after an accepted graph proves that the daemon has
    /// reached them. A later same-generation cursor belongs to the canonical
    /// remote writer, even if it changed the requested name again.
    private func retirePendingRemoteRenames(observed state: CloudVMState) {
        guard let cursor = state.cursor else { return }
        var completed: [PendingRemoteRenameKey] = []
        for (key, pending) in pendingRemoteRenames {
            let shouldRetire: Bool
            if cursor.generation != pending.receipt.generation {
                // `acceptsIncomingGeneration` already rejected known old
                // generations, so a different accepted generation is current.
                shouldRetire = true
            } else if cursor.revision > pending.receipt.revision {
                shouldRetire = true
            } else if cursor.revision == pending.receipt.revision {
                switch key {
                case .workspace(let id):
                    shouldRetire = state.lookupIndex.workspace(id: id)?.name == pending.name
                case .tab(let id):
                    shouldRetire = (state.lookupIndex.tab(id: id)?.name ?? "") == pending.name
                }
            } else {
                shouldRetire = false
            }
            if shouldRetire {
                completed.append(key)
            }
        }
        for key in completed {
            pendingRemoteRenames.removeValue(forKey: key)
        }
    }

    /// Publishes the authoritative graph and every derived row in one catalog
    /// transaction. Display and forwarded-port rows are machine capabilities, so
    /// they join the daemon graph here without becoming a second session state.
    private func publish(
        _ state: CloudVMState,
        ports: [Int],
        reconcileTitles: Bool = true,
        observation: CloudVMStateObservation = .current
    ) {
        var pool: [SurfaceResource] = []
        // The control plane's resolved kind is authoritative. Freestyle snapshot
        // ids are opaque and cannot tell us whether the machine has a desktop.
        if summary.resolvedKind.hasDesktop {
            pool.append(desktopDisplayResource())
        }
        var resources = CmuxTuiSnapshotParser.mergingDisplays(
            pool: pool,
            parsed: CmuxTuiSnapshotParser.resources(from: state)
        )
        resources.append(contentsOf: portResources(ports))
        resources = resourcesWithPendingCreations(resources, state: state)
        if let snapshot = state.snapshotObject() {
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: snapshot)
        }
        info.remoteWorkspaces = remoteWorkspaces(for: state)
        catalog.replaceCloudState(
            state,
            resources: resources,
            info: info,
            observation: observationWithPendingWrites(observation)
        )
        if reconcileTitles {
            catalog.reconcileCloudRemoteState(machine: machine, state: state)
        }
    }

    /// Applies a contiguous event to the catalog's canonical graph. Row-local changes rebuild
    /// only their affected terminal, browser, or display rows. A topology change crosses a
    /// relationship boundary and uses the authoritative complete publication path.
    private func publishDelta(
        _ state: CloudVMState,
        impact: CloudVMStateDeltaImpact,
        ports: [Int],
        reconcileTitles: Bool
    ) {
        if impact.requiresFullResourceRebuild {
            publish(state, ports: ports, reconcileTitles: reconcileTitles)
            return
        }

        var affected = impact.resourceIDs
        // A full publish can erase an optimistic create while its receipt is
        // still ahead of the accepted graph. Include those identities in a
        // delta patch as well, so every publication path applies the same
        // read-your-write overlay atomically.
        affected.formUnion(pendingRemoteCreations.keys)
        var resources = CmuxTuiSnapshotParser.resources(from: state, matching: affected)
        resources = resourcesWithPendingCreations(resources, state: state)
        // A desktop is a machine capability even when no workspace currently points at it.
        // Include that pool row only when the delta actually touched a display identity.
        if summary.resolvedKind.hasDesktop,
           affected.contains(SurfaceResourceID(machine: machine, kind: .display, key: "display:1")) {
            resources = CmuxTuiSnapshotParser.mergingDisplays(
                pool: [desktopDisplayResource()],
                parsed: resources
            )
        }
        info.remoteWorkspaces = remoteWorkspaces(for: state)
        let previousIDs = Set(catalog.snapshot.resources(on: machine).map(\.id))
        let changed = catalog.applyCloudStateResourcePatch(
            state,
            resources: resources,
            affectedResourceIDs: affected,
            info: info,
            observation: observationWithPendingWrites()
        )
        if reconcileTitles {
            catalog.reconcileCloudRemoteState(machine: machine, state: state)
        }
        // A newly restored terminal may need its attach pane materialized. Existing rows do not
        // need a full projection scan for every title event.
        if changed.contains(where: { $0.kind == .terminal && !previousIDs.contains($0) }) {
            reprojectRestoredPanes(generation: lifecycleGeneration)
        }
    }

    private static func remoteWorkspaces(_ state: CloudVMState) -> [SurfaceRemoteWorkspace] {
        state.workspaces.map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        }
    }

    /// Merges pending mutation receipts into derived rows until an accepted
    /// graph reaches each receipt. The canonical graph is never edited here.
    /// A generation change, or a cursorless snapshot after a versioned receipt,
    /// retires the overlay because the old placement cannot be proven to exist.
    private func resourcesWithPendingCreations(
        _ resources: [SurfaceResource],
        state: CloudVMState?
    ) -> [SurfaceResource] {
        var merged = resources
        var completed: [SurfaceResourceID] = []
        for (resourceID, pending) in pendingRemoteCreations where resourceID.machine == machine {
            if let state {
                if let receipt = pending.receipt {
                    guard let cursor = state.cursor,
                          cursor.generation == receipt.generation else {
                        completed.append(resourceID)
                        continue
                    }
                    if cursor.revision >= receipt.revision {
                        // At or beyond the commit, the accepted graph is the
                        // source of truth, including an intentional close.
                        completed.append(resourceID)
                        continue
                    }
                } else if pendingCreationIsVisible(pending, in: state) {
                    // Legacy mutation responses have no ordering fence. Stop
                    // overlaying as soon as the exact path is observed.
                    completed.append(resourceID)
                    continue
                }
            }
            mergePendingCreation(pending, into: &merged)
        }
        for resourceID in completed {
            pendingRemoteCreations.removeValue(forKey: resourceID)
        }
        return merged
    }

    private func pendingCreationIsVisible(
        _ pending: PendingRemoteCreation,
        in state: CloudVMState
    ) -> Bool {
        guard state.lookupIndex.terminal(id: pending.resource.id.key) != nil else { return false }
        guard let tabID = pending.tabID else { return true }
        return state.lookupIndex.tab(id: tabID) != nil
    }

    private func mergePendingCreation(
        _ pending: PendingRemoteCreation,
        into resources: inout [SurfaceResource]
    ) {
        guard let pendingView = pending.resource.remoteViews?.first else {
            if !resources.contains(where: { $0.id == pending.resource.id }) {
                resources.append(pending.resource)
            }
            return
        }
        guard let index = resources.firstIndex(where: { $0.id == pending.resource.id }) else {
            resources.append(pending.resource)
            return
        }
        var resource = resources[index]
        var views = resource.remoteViews ?? []
        if !views.contains(where: { $0.tabID == pendingView.tabID }) {
            views.append(pendingView)
            resource.remoteViews = views
            if resource.remoteWorkspace == nil {
                resource.remoteWorkspace = pendingView.workspace
            }
        }
        resources[index] = resource
    }

    private func remoteWorkspaces(for state: CloudVMState?) -> [SurfaceRemoteWorkspace]? {
        var result = state.map(Self.remoteWorkspaces) ?? info.remoteWorkspaces ?? []
        var seen = Set(result.map(\.id))
        for pending in pendingRemoteCreations.values {
            guard let workspace = pending.resource.remoteWorkspace,
                  seen.insert(workspace.id).inserted else { continue }
            result.append(workspace)
        }
        return result.isEmpty ? nil : result
    }

    private func pendingMutationMetadata() -> [CloudVMPendingMutation] {
        var writes = pendingRemoteCreations.map { resourceID, pending in
            CloudVMPendingMutation(
                kind: .terminalCreate,
                resource: resourceID,
                remoteWorkspaceID: pending.resource.remoteWorkspace?.id,
                remoteTabID: pending.tabID,
                name: pending.resource.remoteViews?.first?.name,
                receipt: pending.receipt
            )
        }
        writes.append(contentsOf: pendingRemoteRenames.map { key, pending in
            switch key {
            case .workspace(let id):
                return CloudVMPendingMutation(
                    kind: .workspaceRename,
                    resource: nil,
                    remoteWorkspaceID: id,
                    remoteTabID: nil,
                    name: pending.name,
                    receipt: pending.receipt
                )
            case .tab(let id):
                return CloudVMPendingMutation(
                    kind: .tabRename,
                    resource: nil,
                    remoteWorkspaceID: nil,
                    remoteTabID: id,
                    name: pending.name,
                    receipt: pending.receipt
                )
            }
        })
        return writes.sorted { left, right in
            if left.kind.rawValue != right.kind.rawValue {
                return left.kind.rawValue < right.kind.rawValue
            }
            let leftID = left.resource?.rawValue ?? left.remoteWorkspaceID ?? left.remoteTabID ?? ""
            let rightID = right.resource?.rawValue ?? right.remoteWorkspaceID ?? right.remoteTabID ?? ""
            return leftID < rightID
        }
    }

    private func observationWithPendingWrites(
        _ base: CloudVMStateObservation = .current
    ) -> CloudVMStateObservation {
        var observation = base
        let pending = pendingMutationMetadata()
        observation.pendingWrites = pending.isEmpty ? nil : pending
        return observation
    }

    private func publishPendingMutationMetadata() {
        catalog.updateCloudPendingWrites(
            on: machine,
            writes: pendingMutationMetadata(),
            from: self
        )
    }

    private func pendingCreation(for resourceID: SurfaceResourceID) -> PendingRemoteCreation? {
        pendingRemoteCreations[resourceID]
    }

    private func pendingCreation(forTabID tabID: String) -> PendingRemoteCreation? {
        pendingRemoteCreations.values.first { $0.tabID == tabID }
    }

    /// Advances a pending receipt after a follow-up rename commits before the
    /// creation snapshot arrives. This keeps the optimistic row and its tab
    /// label coherent without inventing a second canonical graph.
    private func recordPendingRename(tabID: String, name: String, revision: UInt64) {
        for resourceID in Array(pendingRemoteCreations.keys) {
            guard var pending = pendingRemoteCreations[resourceID], pending.tabID == tabID else { continue }
            if let receipt = pending.receipt {
                guard revision >= receipt.revision else { continue }
                pending.receipt = CloudVMCursor(generation: receipt.generation, revision: revision)
            }
            if var views = pending.resource.remoteViews,
               let viewIndex = views.firstIndex(where: { $0.tabID == tabID }) {
                views[viewIndex].name = name
                pending.resource.remoteViews = views
            }
            pendingRemoteCreations[resourceID] = pending
        }
        publishPendingMutationMetadata()
    }

    private func recordPendingRemoteRename(
        workspaceID: String,
        name: String,
        receipt: CloudVMCursor
    ) {
        pendingRemoteRenames[.workspace(workspaceID)] = PendingRemoteRename(
            name: name,
            receipt: receipt
        )
        publishPendingMutationMetadata()
    }

    private func recordPendingRemoteRename(
        tabID: String,
        name: String,
        receipt: CloudVMCursor
    ) {
        pendingRemoteRenames[.tab(tabID)] = PendingRemoteRename(
            name: name,
            receipt: receipt
        )
        publishPendingMutationMetadata()
    }

    private func pendingRemoteRename(for key: PendingRemoteRenameKey) -> PendingRemoteRename? {
        pendingRemoteRenames[key]
    }

    /// Builds forwarded-port rows with the same direct private route used by
    /// the Freestyle attach path. Keeping this derivation in one place avoids
    /// losing the route when a cached or unavailable snapshot is published.
    private func portResources(_ ports: [Int]) -> [SurfaceResource] {
        Self.portResources(
            machine: machine,
            scannedPorts: ports,
            previousResources: catalog.snapshot.resources(on: machine),
            privateAddress: summary.preferredPrivateAddress
        )
    }

    /// Runs one close-family command, reconnecting and retrying ONCE when the attempt
    /// died with the link ("cmux-tui link exited with status …": a dropped tunnel kills
    /// the whole client run). Safe here because every close verb is idempotent — a
    /// second attempt against an already-closed target is `selector.not_found`, which
    /// the callers already tolerate. Non-idempotent verbs (create, run) must not use it.
    private func runCloseCommand(_ arguments: (_ socketPath: String) -> [String]) async throws -> Data {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        do {
            return try await link.run(arguments: arguments(connected.socketPath))
        } catch {
            // selector.not_found is a real answer, not a transport failure.
            if Self.isSelectorNotFound(error) { throw error }
            let reconnected = try await links.connected(machineID: machineID)
            guard let fresh = await links.link(machineID: machineID) else { throw error }
            return try await fresh.run(arguments: arguments(reconnected.socketPath))
        }
    }

    // MARK: Headless terminal I/O (agent primitives; no pane involved)

    /// Type `text` into the remote terminal exactly as given (no newline appended).
    func sendText(terminalID: String, text: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.writeArguments(socketPath: connected.socketPath, terminalID: terminalID, text: text))
    }

    /// Press named keys (`enter`, `ctrl+c`, …) in the remote terminal, in order.
    func sendKeys(terminalID: String, keys: [String]) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.keysArguments(socketPath: connected.socketPath, terminalID: terminalID, keys: keys))
    }

    /// The remote terminal's visible screen, as the daemon reports it
    /// (`cols`, `rows`, `cursor_row`, `cursor_col`, `cursor_visible`, `text`).
    func readScreen(terminalID: String) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.screenReadArguments(socketPath: connected.socketPath, terminalID: terminalID))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Block until the screen matches `pattern` (or the daemon-side timeout elapses):
    /// `{matched, text}`. The link call itself is given headroom beyond the timeout.
    func waitForScreen(terminalID: String, pattern: String, timeoutMs: Int?) async throws -> [String: Any] {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        // Non-positive requests mean the daemon default, so the link headroom is computed
        // from the same value the daemon will use; huge requests are clamped so the
        // Duration math cannot overflow.
        let effectiveMs = Self.clampedWaitTimeoutMs(timeoutMs)
        let linkTimeout = Duration.milliseconds(effectiveMs + 5_000)
        let data = try await link.run(
            arguments: CloudTuiCommandLine.screenWaitArguments(socketPath: connected.socketPath, terminalID: terminalID, pattern: pattern, timeoutMs: effectiveMs),
            timeout: linkTimeout
        )
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `screen wait` default when the caller gives no (or a non-positive) timeout.
    nonisolated static let defaultWaitTimeoutMs = 30_000
    /// Upper bound for one `screen wait` (an hour): long enough for any build, short
    /// enough that the link call and the socket call stay finite.
    nonisolated static let maxWaitTimeoutMs = 3_600_000

    /// Pure, so the nonisolated socket handler can normalize before hopping actors.
    nonisolated static func clampedWaitTimeoutMs(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultWaitTimeoutMs }
        return min(requested, maxWaitTimeoutMs)
    }

    /// `terminal <id> close`; a terminal whose process already exited is gone from
    /// cmux-tui's selectors, so its tab is closed instead. Either way the resource
    /// leaves the catalog now and the next snapshot confirms.
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        pendingRemoteCreations.removeValue(forKey: id)
        do {
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTerminalArguments(socketPath: $0, terminalID: id.key) }
        } catch {
            guard let tabID = tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTabArguments(socketPath: $0, tabID: tabID) }
        }
        closeLocalPanes(showing: [id])
        catalog.remove(id, from: self)
        scheduleRefresh()
    }

    /// A closed terminal has no pane to show any more: every local pane that projected it
    /// goes too, instead of lingering as a dead attach the person has to close by hand.
    private func closeLocalPanes(showing ids: [SurfaceResourceID]) {
        let wanted = Set(ids)
        for projection in catalog.snapshot.projections where wanted.contains(projection.resource) {
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        }
    }

    /// `workspace <id> close`: its tabs go with it, its terminals detach into the pool
    /// (`spec/cli.md`: only `terminal close` kills) — the protocol contract, and what
    /// the sidebar's "Close Workspace (Keep Terminals)" promises. Callers wanting the
    /// full delete (`vm.workspace_delete`, the sidebar's "Delete Workspace and
    /// Terminals…") go through `CloudTreeNodeActions.deleteWorkspaceAndTerminals`,
    /// which closes each terminal first.
    func closeRemoteWorkspace(id: String) async throws {
        _ = try await runCloseCommand { CloudTuiCommandLine.closeWorkspaceArguments(socketPath: $0, workspaceID: id) }
        info.remoteWorkspaces = info.remoteWorkspaces?.filter { $0.id != id }
        catalog.updateMachine(info, from: self)
        scheduleRefresh()
    }

    /// cmux-tui's `selector.not_found` error body, surfaced by `link.run` as the
    /// command's output text.
    private static func isSelectorNotFound(_ error: Error) -> Bool {
        let text = CloudMachineLink.errorText(error)
        return text.contains("selector.not_found") || text.contains("no terminal matches")
    }

    /// The resource CLI exposes optimistic-concurrency failures as either the
    /// structured code or its human-readable text, depending on client version.
    private static func isRevisionConflict(_ error: Error) -> Bool {
        let text = CloudMachineLink.errorText(error).lowercased()
        return text.contains("revision conflict") || text.contains("revision.conflict")
    }

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, remoteView: nil, at: destination, focus: focus)
    }

    func materialize(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        let created: (workspaceID: UUID, panelID: UUID)
        switch resource.kind {
        case .terminal:
            let manual = try await materializeManualMirrorTerminal(
                resource,
                at: destination,
                focus: focus
            )
            created = (manual.workspaceID, manual.panelID)
        case .display, .browser:
            let desktop = resource.kind == .display
            guard let port = resource.id.forwardedPort ?? resource.port ?? (desktop ? CmuxTuiSnapshotParser.desktopPort : nil) else {
                throw SurfaceCatalogError.unsupported("browser \(resource.id) has no port")
            }
            guard let rawURL = resource.url, let directURL = URL(string: rawURL) else {
                throw SurfaceCatalogError.unsupported("browser \(resource.id) has no private URL")
            }
            // Create the pane immediately, but do not navigate to any private
            // address until the Network Extension is connected. This is the
            // only action that can cause the one-time macOS approval request.
            let label = Self.paneLabel(machineID: machineID, port: port, desktop: desktop)
            let machineWasAwake = isAwake
            created = try SurfacePaneFactory.makeBrowserPane(url: SurfacePaneFactory.blankURL, at: destination, focus: focus)
            SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.connecting(label), panelID: created.panelID, in: created.workspaceID)
            let pane = created
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                    try await client.requireCloudBrowserAccess(machineID: self.machineID)
                    if !machineWasAwake {
                        // Waking a paused machine is an explicit management
                        // operation. Ignore the returned URL and keep the
                        // private address captured above.
                        _ = try await client.openPort(id: self.machineID, port: port)
                    }
                    SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: directURL)
                } catch {
                    let text = CloudMachineLink.errorText(error)
                    SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.failed(label, error: text), panelID: pane.panelID, in: pane.workspaceID)
                    #if DEBUG
                    cmuxDebugLog("cloud.provider.endpointFailed machine=\(self.machineID) port=\(port) error=\(String(reflecting: error))")
                    #endif
                }
            }
        }
        materializedPanels.insert(created.panelID)
        let selectedView = remoteView ?? Self.defaultRemoteView(for: resource)
        return SurfaceProjection(
            resource: resource.id,
            workspaceID: created.workspaceID,
            panelID: created.panelID,
            remoteWorkspaceID: selectedView?.workspace.id,
            remoteTabID: selectedView?.tabID
        )
    }

    /// A new terminal in the machine's cmux-tui session (`workspace <ws> run -- argv`).
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let workspaceID: String
        if let remoteWorkspaceID = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteWorkspaceID.isEmpty {
            workspaceID = remoteWorkspaceID
        } else if let existing = catalog.snapshot.resources(on: machine).compactMap(\.remoteWorkspace).sorted(by: { ($0.focused ? 0 : 1, $0.index) < ($1.focused ? 0 : 1, $1.index) }).first {
            workspaceID = existing.id
        } else {
            let created = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(socketPath: connected.socketPath, name: name ?? "main"))
            guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
                  let id = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
                throw ProviderError.noWorkspaceOnMachine(machineID)
            }
            workspaceID = id
        }
        let argv = CloudTuiCommandLine.commandStartingIn(
            cwd: cwd,
            command: (command?.isEmpty == false ? command : nil) ?? CloudTuiCommandLine.defaultTerminalCommand
        )
        let data = try await link.run(arguments: CloudTuiCommandLine.runArguments(socketPath: connected.socketPath, workspaceID: workspaceID, command: argv))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object) else {
            throw ProviderError.terminalNotCreated(String(data: data, encoding: .utf8) ?? "")
        }
        let resolvedWorkspaceID = created.workspaceID ?? workspaceID
        let remoteWorkspace = cloudState?.workspaces.first(where: { $0.id == resolvedWorkspaceID }).map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        } ?? info.remoteWorkspaces?.first(where: { $0.id == resolvedWorkspaceID })
            ?? SurfaceRemoteWorkspace(
                id: resolvedWorkspaceID,
                name: resolvedWorkspaceID,
                index: info.remoteWorkspaces?.count ?? 0,
                focused: false
            )
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: created.terminalID),
            title: name ?? "",
            detail: cwd,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            port: nil,
            url: nil
        )
        if let tabID = created.tabID {
            resource.remoteViews = [SurfaceRemoteView(
                tabID: tabID,
                workspace: remoteWorkspace,
                screenID: created.screenID,
                paneID: created.paneID,
                name: name,
                focused: true
            )]
        } else {
            resource.remoteViews = []
        }
        pendingRemoteCreations[resource.id] = PendingRemoteCreation(
            resource: resource,
            receipt: created.cursor,
            tabID: created.tabID
        )
        catalog.upsert(resource, from: self)
        publishPendingMutationMetadata()
        scheduleRefresh()
        return resource
    }

    /// A new empty workspace in the machine's cmux-tui session (`workspace create`),
    /// called directly — not as a side effect of creating a terminal.
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let existingCount = info.remoteWorkspaces?.count
            ?? Set(catalog.snapshot.resources(on: machine).flatMap { $0.remoteWorkspaces.map(\.id) }).count
        let workspaceName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (existingCount == 0 ? "main" : "workspace-\(existingCount + 1)")
        let created = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(socketPath: connected.socketPath, name: workspaceName))
        guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        let workspace = SurfaceRemoteWorkspace(id: id, name: workspaceName, index: info.remoteWorkspaces?.count ?? 0, focused: false)
        // Optimistic: show the new (empty) workspace now; the next snapshot re-sync is authoritative.
        info.remoteWorkspaces = (info.remoteWorkspaces ?? []) + [workspace]
        catalog.updateMachine(info, from: self)
        scheduleRefresh()
        return workspace
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
        try Task.checkCancellation()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameWorkspaceEmptyName", defaultValue: "A workspace name cannot be empty.")
            )
        }
        // Validate against a fresh document. A cached workspace id can refer to
        // a closed or recycled daemon object after another client changes the VM.
        guard await refresh(force: true),
              let observed = cloudState,
              let previous = observed.workspaces.first(where: { $0.id == id }) else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameWorkspaceNotFound", defaultValue: "This remote workspace is no longer available.")
            )
        }
        guard let observedCursor = observed.cursor else {
            throw ProviderError.snapshotOnly(machineID)
        }
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        try Task.checkCancellation()
        do {
            let receipt = try await sendRenameWorkspace(
                link: link,
                socketPath: connected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: observedCursor.revision
            )
            recordPendingRemoteRename(workspaceID: id, name: normalizedName, receipt: try validatedReceipt(receipt, against: observedCursor))
        } catch {
            // A revision can advance for an unrelated event. Retry once only
            // when this workspace still has the name we observed. If another
            // client changed it, do not overwrite that intent.
            guard Self.isRevisionConflict(error),
                  await refresh(force: true),
                  let latest = cloudState,
                  let current = latest.workspaces.first(where: { $0.id == id }),
                  let latestCursor = latest.cursor,
                  current.name == previous.name else { throw error }
            let retryConnected = try await links.connected(machineID: machineID)
            guard let retryLink = await links.link(machineID: machineID) else { throw error }
            let retryReceipt = try await sendRenameWorkspace(
                link: retryLink,
                socketPath: retryConnected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: latestCursor.revision
            )
            recordPendingRemoteRename(workspaceID: id, name: normalizedName, receipt: try validatedReceipt(retryReceipt, against: latestCursor))
        }
        // The command response is not the source of truth. Wait for the next
        // accepted snapshot/event so every local projection sees the same name.
        try Task.checkCancellation()
        _ = await refresh(force: true)
    }

    /// Rename one placement-local daemon tab. This is the canonical path used by a
    /// cloud-tree workspace row and by a local pane that remembers its remote tab id.
    func renameRemoteTab(id: String, name: String) async throws {
        try Task.checkCancellation()
        let normalizedName = CloudRemoteRenameName(rawValue: name).wireValue

        // Creation and rename can arrive back-to-back. Refresh before validating the
        // target, but use the creation receipt when the accepted snapshot still
        // trails it. The receipt's revision is a CAS fence, not a timing guess.
        let refreshEstablishedCurrentGraph = await refresh(force: true)
        try Task.checkCancellation()
        let pendingCreation = pendingCreation(forTabID: id)
        let pendingRename = pendingRemoteRename(for: .tab(id))
        let observed = cloudState
        let previous = observed?.tabs.first(where: { $0.id == id })
        let observedCursor = observed?.cursor
        let pendingReceipt = [pendingCreation?.receipt, pendingRename?.receipt]
            .compactMap { $0 }
            .filter { receipt in
                guard let observedCursor else { return true }
                return receipt.generation == observedCursor.generation
            }
            .max { $0.revision < $1.revision }
        let authority = CloudVMRemoteMutationAuthority.resolve(
            refreshEstablishedCurrentGraph: refreshEstablishedCurrentGraph,
            hasAcceptedState: observed != nil,
            targetVisible: previous != nil,
            hasVersionedCursor: observedCursor != nil,
            hasPendingReceipt: pendingReceipt != nil
        )
        switch authority {
        case .currentGraph:
            guard let previous, let observedCursor else {
                throw ProviderError.stateUnavailable(machineID)
            }
            do {
                let receipt = try await sendRenameTab(
                    id: id,
                    name: normalizedName,
                    expectedRevision: observedCursor.revision
                )
                let validated = try validatedReceipt(receipt, against: observedCursor)
                recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
                recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
            } catch {
                guard Self.isRevisionConflict(error),
                      await refresh(force: true),
                      let latest = cloudState,
                      let current = latest.tabs.first(where: { $0.id == id }),
                      let latestCursor = latest.cursor,
                      (current.name ?? "") == (previous.name ?? "") else { throw error }
                let receipt = try await sendRenameTab(
                    id: id,
                    name: normalizedName,
                    expectedRevision: latestCursor.revision
                )
                let validated = try validatedReceipt(receipt, against: latestCursor)
                recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
                recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
            }
        case .pendingReceipt:
            guard let receipt = pendingReceipt else {
                throw ProviderError.stateUnavailable(machineID)
            }
            let committed = try await sendRenameTab(
                id: id,
                name: normalizedName,
                expectedRevision: receipt.revision
            )
            let validated = try validatedReceipt(committed, against: receipt)
            recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
            recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
        case .snapshotOnly:
            throw ProviderError.snapshotOnly(machineID)
        case .unavailable:
            throw ProviderError.stateUnavailable(machineID)
        case .targetMissing:
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }
        // The daemon event normally installs this before the command exits. The
        // explicit read is the barrier for older clients that do not stream deltas.
        try Task.checkCancellation()
        _ = await refresh(force: true)
    }

    /// Compatibility operation for callers that intentionally mean “all views”.
    /// It is kept separate from `renameRemoteTab` so an ambiguous terminal identity
    /// can never silently rename an arbitrary placement.
    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
        try Task.checkCancellation()
        let normalizedName = CloudRemoteRenameName(rawValue: name).wireValue
        // The daemon's tab name is placement-local. Keep one target per exact
        // tab id, and use the fresh typed state for the old value. A creation
        // receipt supplies the one exact tab while the first snapshot catches
        // up, so an immediate rename cannot lose its target.
        let refreshEstablishedCurrentGraph = await refresh(force: true)
        try Task.checkCancellation()
        let pending = pendingCreation(for: id)
        let observed = cloudState
        // Derive every placement from the freshly accepted canonical graph. The
        // catalog is a projection and may still contain a row from an older
        // publication, so it cannot authorize a compatibility fan-out.
        let freshTargets: [(tabID: String, previousName: String)] = {
            guard refreshEstablishedCurrentGraph,
                  let observed,
                  observed.cursor != nil,
                  observed.lookupIndex.terminal(id: id.key) != nil else { return [] }
            return observed.lookupIndex
                .tabs(contentKind: "terminal", contentID: id.key)
                .map { ($0.id, $0.name ?? "") }
        }()
        let authority = CloudVMRemoteMutationAuthority.resolve(
            refreshEstablishedCurrentGraph: refreshEstablishedCurrentGraph,
            hasAcceptedState: observed != nil,
            targetVisible: !freshTargets.isEmpty,
            hasVersionedCursor: observed?.cursor != nil,
            hasPendingReceipt: pending?.tabID != nil && pending?.receipt != nil
        )
        let observedCursor: CloudVMCursor
        let targets: [(tabID: String, previousName: String)]
        switch authority {
        case .currentGraph:
            guard let cursor = observed?.cursor, !freshTargets.isEmpty else {
                throw ProviderError.stateUnavailable(machineID)
            }
            observedCursor = cursor
            targets = freshTargets
        case .pendingReceipt:
            guard let pending,
                  let receipt = pending.receipt,
                  let tabID = pending.tabID else {
                throw ProviderError.stateUnavailable(machineID)
            }
            observedCursor = receipt
            let previousName = pending.resource.remoteViews?.first(where: { $0.tabID == tabID })?.name ?? ""
            targets = [(tabID, previousName)]
        case .snapshotOnly:
            throw ProviderError.snapshotOnly(machineID)
        case .unavailable:
            throw ProviderError.stateUnavailable(machineID)
        case .targetMissing:
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }

        // Do not spend a revision on a view that already has the requested name.
        // This also reduces the window in which another client can race the
        // compatibility fan-out.
        let pendingTargets = targets.filter { $0.previousName != normalizedName }
        if pendingTargets.isEmpty { return }

        var lastCommitCursor = observedCursor
        var renamedTabs: [(tabID: String, previousName: String, commitCursor: CloudVMCursor)] = []
        var mutationOutcomeUncertain = false
        do {
            for target in pendingTargets {
                try Task.checkCancellation()
                do {
                    let receipt = try await sendRenameTab(
                        id: target.tabID,
                        name: normalizedName,
                        expectedRevision: lastCommitCursor.revision
                    )
                    let validated = try validatedReceipt(receipt, against: lastCommitCursor)
                    renamedTabs.append((target.tabID, target.previousName, validated))
                    lastCommitCursor = validated
                    recordPendingRemoteRename(tabID: target.tabID, name: normalizedName, receipt: validated)
                    recordPendingRename(tabID: target.tabID, name: normalizedName, revision: validated.revision)
                } catch {
                    // A revision conflict is a known refusal before this step
                    // commits. Transport or malformed-response errors are
                    // indeterminate: the daemon may have committed before the
                    // link failed, so compensation would be unsafe.
                    if !Self.isRevisionConflict(error) { mutationOutcomeUncertain = true }
                    throw error
                }
            }
        } catch {
            // Compensation is allowed only when a fresh snapshot proves that
            // no event followed the last known commit and every completed tab
            // still carries our requested name. Each restore is itself fenced,
            // so a concurrent rename between checks cannot be overwritten.
            var compensated = renamedTabs.isEmpty
            if !renamedTabs.isEmpty, !mutationOutcomeUncertain,
               await refresh(force: true),
               let latest = cloudState,
               let latestCursor = latest.cursor,
               latestCursor.generation == observedCursor.generation,
               latestCursor == lastCommitCursor,
               renamedTabs.allSatisfy({ entry in
                   latest.lookupIndex.tab(id: entry.tabID)?.name == normalizedName
               }) {
                compensated = true
                var compensationCursor = latestCursor
                for entry in renamedTabs.reversed() {
                    do {
                        let receipt = try await sendRenameTab(
                            id: entry.tabID,
                            name: entry.previousName,
                            expectedRevision: compensationCursor.revision
                        )
                        let validated = try validatedReceipt(receipt, against: compensationCursor)
                        compensationCursor = validated
                        recordPendingRemoteRename(tabID: entry.tabID, name: entry.previousName, receipt: validated)
                        recordPendingRename(tabID: entry.tabID, name: entry.previousName, revision: validated.revision)
                    } catch {
                        compensated = false
                        break
                    }
                }
            }
            _ = await refresh(force: true)
            if !compensated {
                throw Self.partialRenameError(
                    id: id,
                    applied: renamedTabs.count,
                    total: pendingTargets.count
                )
            }
            throw error
        }
        _ = await refresh(force: true)
    }

    @discardableResult
    private func sendRenameWorkspace(
        link: CloudMachineLink,
        socketPath: String,
        workspaceID: String,
        name: String,
        expectedRevision: UInt64?
    ) async throws -> CloudVMCursor? {
        let data = try await link.run(arguments: CloudTuiCommandLine.renameWorkspaceArguments(
            socketPath: socketPath,
            workspaceID: workspaceID,
            name: name,
            expectedRevision: expectedRevision
        ))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteRenameError.invalidResponse
        }
        return CmuxTuiSnapshotParser.mutationCursor(fromResult: object)
    }

    private func sendRenameTab(id: String, name: String, expectedRevision: UInt64? = nil) async throws -> CloudVMCursor {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.renameTabArguments(
            socketPath: connected.socketPath,
            tabID: id,
            name: name,
            expectedRevision: expectedRevision
        ))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteRenameError.invalidResponse
        }
        guard let receipt = CmuxTuiSnapshotParser.mutationCursor(fromResult: object) else {
            throw RemoteRenameError.invalidResponse
        }
        return receipt
    }

    private func validatedReceipt(
        _ receipt: CloudVMCursor?,
        against expected: CloudVMCursor
    ) throws -> CloudVMCursor {
        guard let receipt else { throw RemoteRenameError.invalidResponse }
        guard receipt.generation == expected.generation else {
            throw RemoteRenameError.generationChanged(expected: expected.generation, received: receipt.generation)
        }
        guard receipt.revision > expected.revision else {
            throw RemoteRenameError.nonMonotonicRevision(
                expectedAtLeast: expected.revision == UInt64.max ? UInt64.max : expected.revision + 1,
                received: receipt.revision
            )
        }
        return receipt
    }

    private enum RemoteRenameError: Error, LocalizedError {
        case invalidResponse
        case generationChanged(expected: String, received: String)
        case nonMonotonicRevision(expectedAtLeast: UInt64, received: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "cloudTree.error.renameTerminalResponse", defaultValue: "The remote rename response was invalid. Refresh and retry.")
            case .generationChanged:
                return String(localized: "cloudTree.error.renameTerminalGeneration", defaultValue: "The remote rename came from a different VM session. Refresh and retry.")
            case .nonMonotonicRevision(let expected, let received):
                return String(format: String(localized: "cloudTree.error.renameTerminalRevision", defaultValue: "The remote rename returned revision %2$llu after revision %1$llu. Refresh and retry."), expected, received)
            }
        }
    }

    private static func partialRenameError(
        id: SurfaceResourceID,
        applied: Int,
        total: Int
    ) -> SurfaceCatalogError {
        let reason = String(format: String(
            localized: "cloudTree.error.renameTerminalPartial",
            defaultValue: "Terminal rename changed %1$d of %2$d remote tabs. Another change prevented a safe rollback. Refresh and retry."
        ), applied, total)
        return .partialOperation(id, reason: reason)
    }

    /// The terminal lives in the machine's session; only the local pane went away.
    func projectionDidEnd(_ projection: SurfaceProjection) {
        materializedPanels.remove(projection.panelID)
        manualMirrorSessions.removeValue(forKey: projection.panelID)?.stop()
    }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        materializedPanels.remove(projection.panelID)
        manualMirrorSessions.removeValue(forKey: projection.panelID)?.stop()
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }

    // MARK: - internals

    private static func info(from summary: VMSummary, linkState: SurfaceLinkState, linkError: String?, stats: VMStats?, remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .cloud(summary.id),
            name: summary.preferredName,
            status: summary.status,
            image: summary.image,
            hasDesktop: summary.resolvedKind.hasDesktop,
            memoryMb: stats?.memoryTotalMb,
            diskMb: stats?.diskTotalMb,
            linkState: linkState,
            linkError: linkError,
            cpuPercent: stats?.cpuPercent,
            memoryUsedMb: stats?.memoryUsedMb,
            diskUsedMb: stats?.diskUsedMb,
            remoteWorkspaces: remoteWorkspaces,
            privateAddress: summary.preferredPrivateAddress
        )
    }

    /// Appends preserved resources without repeatedly scanning the growing
    /// snapshot array. Refresh fallback paths run on the main actor, so keeping
    /// this linear is important for machines with many remote views.
    private func appendMissingResources(
        _ preserved: [SurfaceResource],
        to resources: inout [SurfaceResource]
    ) {
        var knownIDs = Set(resources.map(\.id))
        for resource in preserved where knownIDs.insert(resource.id).inserted {
            resources.append(resource)
        }
    }

    /// Compatibility fallback for callers that only have a terminal identity. A terminal with
    /// several views has no safe implicit placement. Returning nil keeps the projection
    /// placement-neutral until a caller supplies an exact tab id.
    private static func defaultRemoteView(for resource: SurfaceResource) -> SurfaceRemoteView? {
        guard let views = resource.remoteViews, views.count == 1 else { return nil }
        return views[0]
    }

    private func attachCommand(terminalID: String) async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let clientURL = CloudTuiClientPaths.clientURL() else {
            throw CloudMachineLinkManager.ManagerError.clientMissing
        }
        return CloudTuiCommandLine.attachShellCommand(clientPath: clientURL.path, socketPath: connected.socketPath, terminalID: terminalID)
    }

    /// The tokened wrapper URL the control plane mints for a port; the desktop adds the
    /// noVNC query the `cmux vm desktop` recipe uses.
    /// What the connecting/failure screen calls the pane: "<machine> · Desktop" or "<machine>:<port>".
    static func paneLabel(machineID: String, port: Int, desktop: Bool) -> String {
        desktop
            ? "\(machineID) · \(String(localized: "cloudTree.node.desktop", defaultValue: "Desktop"))"
            : "\(machineID):\(port)"
    }

    /// The desktop row. Its URL is the machine's private noVNC address, so opening it
    /// never needs a provider preview endpoint; nil until the machine has an address.
    private func desktopDisplayResource() -> SurfaceResource {
        CmuxTuiSnapshotParser.display(
            machine: machine,
            directURL: summary.preferredPrivateAddress.map { Self.privateDesktopURL(privateAddress: $0) }
        )
    }

    /// The noVNC URL uses only the VM private address. The private network is
    /// the access check, so no public preview token or endpoint is required.
    nonisolated static func privateDesktopURL(privateAddress: String) -> String {
        let base = CmuxInternalHostnames.directPortURL(
            privateAddress: privateAddress,
            port: CmuxTuiSnapshotParser.desktopPort
        )
        return "\(base)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }

    /// Turn a VM-local browser URL into the same URL on the VM private address.
    /// Path, query, fragment, scheme, and port stay unchanged.
    nonisolated static func privateBrowserURL(_ raw: String, privateAddress: String) -> String? {
        guard var parts = URLComponents(string: raw),
              let host = parts.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" else {
            return nil
        }
        parts.host = privateAddress
        return parts.url?.absoluteString
    }

    /// Add the local URL used when this resource is projected on the Mac.
    nonisolated static func withPrivateBrowserURL(
        _ resource: SurfaceResource,
        privateAddress: String
    ) -> SurfaceResource {
        var updated = resource
        switch resource.kind {
        case .display:
            updated.url = privateDesktopURL(privateAddress: privateAddress)
        case .browser:
            if resource.id.key.hasPrefix("port:"), let port = resource.port {
                updated.url = CmuxInternalHostnames.directPortURL(
                    privateAddress: privateAddress,
                    port: port
                )
            } else if let raw = resource.url {
                updated.url = privateBrowserURL(raw, privateAddress: privateAddress)
            }
        case .terminal:
            break
        }
        return updated
    }

    private func ports(
        link: CloudMachineLink,
        socketPath: String,
        force: Bool,
        generation: UInt64,
        privateAddress: String?
    ) async -> [Int]? {
        if !force, let cached = portsCache, Date.now.timeIntervalSince(cached.at) < portsTTL {
            return cached.ports
        }
        guard let arguments = CloudTuiCommandLine.listeningPortsArguments(socketPath: socketPath),
              let data = try? await link.run(arguments: arguments),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stdout = object["stdout"] as? String else {
            return nil
        }
        let result = VMExecResult(exitCode: 0, stdout: stdout, stderr: "")
        guard let ports = Self.ports(from: result, privateAddress: privateAddress) else { return nil }
        guard generation == refreshGeneration else { return nil }
        portsCache = (ports, Date.now)
        return ports
    }

    private func watchChanges(link: CloudMachineLink, generation: UInt64) {
        guard generation == lifecycleGeneration else { return }
        if let watchedLink, watchedLink === link, changeWatcher != nil { return }
        changeWatcher?.cancel()
        let watcherID = UUID()
        watchedLink = link
        changeWatcherID = watcherID
        changeWatcher = Task { [weak self] in
            for await change in link.changes {
                guard let self else { return }
                guard self.lifecycleGeneration == generation else { return }
                await self.handle(change, from: link)
            }
            await MainActor.run { [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.changeWatcherDidEnd(watcherID)
            }
        }
    }

    private func changeWatcherDidEnd(_ watcherID: UUID) {
        guard changeWatcherID == watcherID else { return }
        changeWatcher = nil
        watchedLink = nil
        changeWatcherID = nil
        scheduleRefresh()
    }

    private func handle(_ change: CloudMachineLink.Change, from link: CloudMachineLink) async {
        // Events from a retired link can arrive after a reconnect. They are
        // never allowed to mutate the graph owned by the replacement link.
        guard watchedLink === link else { return }
        switch change {
        case .connected:
            if cloudState == nil { scheduleRefresh() }

        case .snapshot(let cursor, _, let payload):
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let incoming = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
                  incoming.cursor == cursor else {
                scheduleStateRecoveryRefresh()
                return
            }
            if installSnapshotIfNewer(incoming) {
                clearStateRecovery()
                await link.setEventsCursor(incoming.cursor)
                var subscriptionResumed = false
                if let cursor = incoming.cursor {
                    subscriptionResumed = await link.resumeEventsSubscription(from: cursor)
                }
                if CloudVMEventFeedRecoveryDecision.shouldClearWarning(
                    snapshotCursor: incoming.cursor,
                    subscriptionResumed: subscriptionResumed
                ) {
                    eventsFeedWarning = nil
                }
                info.linkState = .connected
                info.linkError = nil
                publish(incoming, ports: portsCache?.ports ?? [])
                reprojectRestoredPanes(generation: lifecycleGeneration)
            }

        case .delta(let cursor, let previousRevision, let revision, let payload):
            switch CloudVMStateSyncDecision.forDelta(
                generation: cursor.generation,
                previousRevision: previousRevision,
                revision: revision,
                current: cloudState?.cursor
            ) {
            case .ignoreStale:
                return
            case .fetchSnapshot:
                // A gap is the same synchronization barrier as a malformed event. Route it
                // through the single bounded recovery owner so a burst of out-of-order events
                // cannot start one full snapshot request per line.
                scheduleStateRecoveryRefresh()
            case .installSnapshot:
                guard let current = cloudState,
                      cursor.revision == revision,
                      let application = CmuxTuiSnapshotParser.applyingWithImpact(
                        deltaPayload: payload,
                        cursor: cursor,
                        to: current
                      ),
                      application.state.cursor == cursor else {
                    scheduleStateRecoveryRefresh()
                    return
                }
                let next = application.state
                guard acceptsIncomingGeneration(next.cursor),
                      incomingPassesPendingRenameFence(next) else {
                    // A contiguous delta that still precedes or contradicts a
                    // mutation receipt is a synchronization barrier. Keep the
                    // last accepted graph and ask for one complete snapshot.
                    scheduleStateRecoveryRefresh()
                    return
                }
                cloudState = next
                cloudStateInstallVersion &+= 1
                acceptedCloudGenerations.insert(cursor.generation)
                retirePendingRemoteRenames(observed: next)
                eventsFeedWarning = nil
                clearStateRecovery()
                await link.setEventsCursor(next.cursor)
                info.linkState = .connected
                info.linkError = nil
                let titlesChanged = current.workspaces != next.workspaces || current.tabs != next.tabs
                publishDelta(
                    next,
                    impact: application.impact,
                    ports: portsCache?.ports ?? [],
                    reconcileTitles: titlesChanged
                )
            }

        case .streamEnded(let reason, _):
            // A stream gap, unknown item, or transport end is a full-state
            // barrier. The snapshot command is the only safe recovery source;
            // CloudMachineLink owns bounded event-feed recovery. The provider
            // must not independently restart the same stream.
            if reason == CloudMachineLink.eventsRecoveryExhaustedReason {
                eventsFeedWarning = reason
            }
            scheduleStateRecoveryRefresh()

        case .unknown:
            // An unknown item is a synchronization barrier, but it is not proof that the
            // transport is dead. Coalesce the expensive snapshot repair and stop after a small
            // bounded number of recovery attempts from one broken stream.
            scheduleStateRecoveryRefresh()
        }
    }

    /// Coalesces malformed, unknown, and relationship-invalid events behind one bounded
    /// snapshot refresh. A daemon can emit many bad lines during a protocol mismatch; one
    /// pending task and a finite budget protect both the machine and the UI from a refresh
    /// storm while preserving a visible warning after recovery is exhausted.
    private func scheduleStateRecoveryRefresh() {
        guard stateRecoveryCount < Self.stateRecoveryLimit else {
            eventsFeedWarning = "state_recovery_exhausted"
            stateRecoveryRefreshQueued = false
            return
        }
        stateRecoveryCount += 1
        stateRecoveryRefreshQueued = true
        guard stateRecoveryRefreshTask == nil else { return }
        stateRecoveryRefreshTask = Task { @MainActor [weak self] in
            // Yield one actor turn to coalesce a burst of barrier events. This is
            // an ordering boundary, not a guessed transport delay.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.stateRecoveryRefreshTask = nil
            guard self.stateRecoveryRefreshQueued else { return }
            self.stateRecoveryRefreshQueued = false
            await self.refresh(force: true)
            if self.stateRecoveryRefreshQueued {
                self.scheduleStateRecoveryRefresh()
            }
        }
    }

    private func clearStateRecovery() {
        stateRecoveryRefreshTask?.cancel()
        stateRecoveryRefreshTask = nil
        stateRecoveryRefreshQueued = false
        stateRecoveryCount = 0
    }

    /// Mutations also request a snapshot as a safety check. One main-actor yield
    /// coalesces calls made in the same transaction without adding a time guess.
    func scheduleRefresh() {
        let lifecycle = lifecycleGeneration
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.scheduledRefresh = nil
            guard self.lifecycleGeneration == lifecycle, self.isRegisteredInCatalog() else { return }
            await self.refresh(force: false)
        }
    }

    /// A restored session brings back the pane (with its UUID) but not the attach process:
    /// the catalog resolved the record into a projection whose panel is a placeholder shell.
    /// Replace it in place with a real attach pane, as a tab of the same pane, then close
    /// the placeholder.
    private func reprojectRestoredPanes(generation: UInt64) {
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { return }
        let terminals = catalog.snapshot.resources(on: machine).filter { $0.kind == .terminal }
        for terminal in terminals {
            for projection in catalog.projections(of: terminal.id) where !materializedPanels.contains(projection.panelID) {
                guard AppDelegate.shared?.workspace(containingSurfaceID: projection.panelID) != nil,
                      let paneID = SurfacePaneFactory.paneID(ofPanel: projection.panelID, in: projection.workspaceID) else {
                    continue
                }
                // Claimed before the async hop so a burst of refreshes cannot re-project twice.
                materializedPanels.insert(projection.panelID)
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentLifecycleGeneration(generation) else { return }
                    await self.reprojectManualMirror(
                        resource: terminal,
                        projection: projection,
                        paneID: paneID,
                        generation: generation
                    )
                }
            }
        }
    }
}
