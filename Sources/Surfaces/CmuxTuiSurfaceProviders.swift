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
    private var pollTask: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var refreshInFlight: Task<Void, Never>?
    /// Same cadence as the Machines panel's list refresh.
    private let pollInterval: Duration = .seconds(45)

    init(links: CloudMachineLinkManager = CloudMachineLinkManager()) {
        self.links = links
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
    func refresh(force: Bool) async {
        if let inFlight = refreshInFlight, !force {
            await inFlight.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh(force: force)
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
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

    // MARK: - internals

    private func performRefresh(force: Bool) async {
        guard let catalog, let client = VMClient.shared else { return }
        guard let page = try? await client.listPage() else { return }
        let seen = Set(page.vms.map(\.id))
        for id in providers.keys where !seen.contains(id) {
            providers[id]?.stop()
            providers[id] = nil
            catalog.unregister(machine: .cloud(id))
        }
        await links.retain(machineIDs: seen)
        for summary in page.vms {
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
    }

    private func accessDidEnd() async {
        for provider in providers.values { provider.stop() }
        for id in providers.keys { catalog?.unregister(machine: .cloud(id)) }
        providers.removeAll()
        await links.disconnectAll()
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
    /// The only installed daemon graph for this machine. The catalog receives the
    /// same immutable value with its derived rows in one transaction.
    private(set) var cloudState: CloudVMState?
    /// Local ordering fence for concurrent snapshot commands and the event
    /// reader. Remote generations are opaque, so a response from an older
    /// request must not replace a generation installed later in the same turn.
    private var cloudStateInstallVersion: UInt64 = 0
    /// A failed event feed is a transport warning, separate from the freshness of the last
    /// accepted snapshot. Agents can read the exact graph and the warning in one export.
    private var eventsFeedWarning: String?
    private var stateRecoveryRefreshTask: Task<Void, Never>?
    private var stateRecoveryRefreshQueued = false
    private var stateRecoveryCount = 0
    private let refreshClock: any Clock<Duration>
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
    /// Preview endpoints already minted for this machine's ports (``SurfacePortEndpointCache``):
    /// reused by the next projection and minted ahead of time for the desktop, so a dropped
    /// display row gets a pane that is already navigating.
    private var endpoints = SurfacePortEndpointCache()
    private var endpointPrefetch: Task<Void, Never>?
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

    init(
        summary: VMSummary,
        links: CloudMachineLinkManager,
        catalog: SurfaceCatalog,
        refreshClock: any Clock<Duration> = ContinuousClock()
    ) {
        machineID = summary.id
        self.summary = summary
        self.links = links
        self.catalog = catalog
        self.refreshClock = refreshClock
        info = Self.info(from: summary, linkState: summary.status == "running" ? .connecting : .asleep, linkError: nil, stats: nil)
    }

    var isAwake: Bool { summary.status == "running" }

    func update(summary: VMSummary) {
        self.summary = summary
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
            catalog.updateMachine(info)
        }
    }

    func stop() {
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
        endpointPrefetch?.cancel()
        endpointPrefetch = nil
        for session in manualMirrorSessions.values { session.stop() }
        manualMirrorSessions.removeAll()
        manualMirrorSurfaceIDsSocketPath = nil
        for task in remoteTerminalProjectionTasks.values { task.cancel() }
        remoteTerminalProjectionTasks.removeAll()
    }

    // MARK: - SurfaceProvider

    func refresh() async {
        await refresh(force: false)
    }

    /// Re-syncs from the machine. A sleeping machine is never woken to be listed: it keeps
    /// its screen (opening it wakes the machine) and nothing else.
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        let machine = self.machine
        let requestVersion = cloudStateInstallVersion
        // The backend's explicit kind is authoritative. Inferring a desktop from
        // an image name would misclassify the shared shell-only Freestyle image.
        let hasDesktop = summary.resolvedKind.hasDesktop
        var currentPorts = portsCache?.ports ?? []
        guard isAwake, let client = VMClient.shared else {
            cloudStateInstallVersion &+= 1
            tabByTerminal = [:]
            let remoteWorkspaces = cloudState.map(Self.remoteWorkspaces)
            let linkState: SurfaceLinkState = isAwake ? .unavailable : .asleep
            let linkError: String? = isAwake ? "cloud_api_unavailable" : nil
            info = Self.info(from: summary, linkState: linkState, linkError: linkError, stats: nil)
            info.remoteWorkspaces = remoteWorkspaces
            let resources: [SurfaceResource]
            if let cloudState {
                resources = CmuxTuiSnapshotParser.mergingDisplays(
                    pool: hasDesktop ? [CmuxTuiSnapshotParser.display(machine: machine)] : [],
                    parsed: CmuxTuiSnapshotParser.resources(from: cloudState)
                ) + portResources(currentPorts)
            } else {
                resources = hasDesktop ? [CmuxTuiSnapshotParser.display(machine: machine)] : []
            }
            catalog.replaceUnavailableCloudState(on: machine, resources: resources, info: info)
            return false
        }
        // The display opens over the HTTPS preview and never needs the link, so a
        // machine with no resources yet gets it published before the link attempt —
        // a slow or hanging connect must not leave the desktop unopenable.
        if hasDesktop, catalog.snapshot.resources(on: machine).isEmpty {
            catalog.replaceResources([CmuxTuiSnapshotParser.display(machine: machine)], on: machine, info: info)
        }
        if hasDesktop {
            prefetchDesktopEndpoint()
        }
        async let stats = try? client.stats(id: machineID)
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        // A successfully decoded snapshot is a successful read even when it
        // loses an install race to a newer event. Callers must never use an old
        // cached graph as proof that the target was freshly observed.
        var snapshotReadSucceeded = false
        do {
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            watchChanges(link: link)
            let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let incoming = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine)
            else { throw ProviderError.invalidSnapshot(machineID) }
            snapshotReadSucceeded = true
            _ = installSnapshotIfNewer(incoming, requestVersion: requestVersion)
            // Derive compatibility maps from the graph that won the install race.
            // The event reader may have advanced it while this snapshot was in flight.
            let authoritative = cloudState?.snapshotObject() ?? object
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: authoritative)
            tabNameByID = CmuxTuiSnapshotParser.tabNames(fromSnapshot: authoritative)
            await link.setEventsCursor(cloudState?.cursor)
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
            await link.resumeEventsSubscription(from: cloudState?.cursor)
            currentPorts = await ports(client: client, force: force)
        } catch {
            let status = await links.status(machineID: machineID)
            linkError = eventsFeedWarning ?? status?.error ?? CloudMachineLink.errorText(error)
            linkState = eventsFeedWarning == nil ? (status?.state ?? .error) : .error
            #if DEBUG
            cmuxDebugLog("cloud.provider.refreshFailed machine=\(machineID) state=\(linkState) error=\(String(reflecting: error))")
            #endif
        }
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
            // current. A failed read keeps the graph for diagnosis but marks it
            // stale, so agents can see it without treating it as writable truth.
            let stateAdvancedDuringRead = cloudStateInstallVersion != requestVersion
            // A successful snapshot is current even when the subscription is degraded. The
            // warning stays in machine info, so agents see both the exact last read and the
            // missing live-feed guarantee instead of an apparently permanent stale graph.
            let observation: CloudVMStateObservation = (snapshotReadSucceeded || stateAdvancedDuringRead)
                ? .current
                : .stale(reason: eventsFeedWarning ?? info.linkError ?? info.linkState.rawValue)
            publish(
                cloudState,
                ports: currentPorts,
                reconcileTitles: snapshotReadSucceeded || stateAdvancedDuringRead,
                observation: observation
            )
        } else {
            let resources = hasDesktop ? [CmuxTuiSnapshotParser.display(machine: machine)] : []
            catalog.replaceResources(resources, on: machine, info: info)
        }
        reprojectRestoredPanes()
        return snapshotReadSucceeded
    }

    @discardableResult
    private func installSnapshotIfNewer(_ incoming: CloudVMState, requestVersion: UInt64? = nil) -> Bool {
        switch CloudVMStateSyncDecision.forSnapshot(
            incoming: incoming.cursor,
            current: cloudState?.cursor
        ) {
        case .ignoreStale:
            return false
        case .installSnapshot:
            if let current = cloudState,
               current.cursor.generation != incoming.cursor.generation,
               let requestVersion,
               requestVersion != cloudStateInstallVersion {
                return false
            }
            cloudState = incoming
            cloudStateInstallVersion &+= 1
            return true
        case .fetchSnapshot:
            return false
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
            pool.append(CmuxTuiSnapshotParser.display(machine: machine))
        }
        var resources = CmuxTuiSnapshotParser.mergingDisplays(
            pool: pool,
            parsed: CmuxTuiSnapshotParser.resources(from: state)
        )
        resources.append(contentsOf: portResources(ports))
        if let snapshot = state.snapshotObject() {
            tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: snapshot)
        }
        info.remoteWorkspaces = Self.remoteWorkspaces(state)
        catalog.replaceCloudState(state, resources: resources, info: info, observation: observation)
        if reconcileTitles {
            CloudWorkspaceRenameWriteThrough.reconcileRemoteState(machine: machine, state: state)
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

        let affected = impact.resourceIDs
        var resources = CmuxTuiSnapshotParser.resources(from: state, matching: affected)
        // A desktop is a machine capability even when no workspace currently points at it.
        // Include that pool row only when the delta actually touched a display identity.
        if summary.resolvedKind.hasDesktop,
           affected.contains(SurfaceResourceID(machine: machine, kind: .display, key: "display:1")) {
            resources = CmuxTuiSnapshotParser.mergingDisplays(
                pool: [CmuxTuiSnapshotParser.display(machine: machine)],
                parsed: resources
            )
        }
        info.remoteWorkspaces = Self.remoteWorkspaces(state)
        let previousIDs = Set(catalog.snapshot.resources(on: machine).map(\.id))
        let changed = catalog.applyCloudStateResourcePatch(
            state,
            resources: resources,
            affectedResourceIDs: affected,
            info: info
        )
        if reconcileTitles {
            CloudWorkspaceRenameWriteThrough.reconcileRemoteState(machine: machine, state: state)
        }
        // A newly restored terminal may need its attach pane materialized. Existing rows do not
        // need a full projection scan for every title event.
        if changed.contains(where: { $0.kind == .terminal && !previousIDs.contains($0) }) {
            reprojectRestoredPanes()
        }
    }

    private static func remoteWorkspaces(_ state: CloudVMState) -> [SurfaceRemoteWorkspace] {
        state.workspaces.map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        }
    }

    /// Builds forwarded-port rows with the same direct private route used by
    /// the Freestyle attach path. Keeping this derivation in one place avoids
    /// losing the route when a cached or unavailable snapshot is published.
    private func portResources(_ ports: [Int]) -> [SurfaceResource] {
        let privateAddress = summary.preferredPrivateAddress
        return ports.map { port in
            let directURL = privateAddress.map {
                CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port)
            }
            return CmuxTuiSnapshotParser.portBrowser(
                machine: machine,
                port: port,
                directURL: directURL
            )
        }
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
        do {
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTerminalArguments(socketPath: $0, terminalID: id.key) }
        } catch {
            guard let tabID = tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTabArguments(socketPath: $0, tabID: tabID) }
        }
        closeLocalPanes(showing: [id])
        catalog.remove(id)
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
        catalog.updateMachine(info)
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
            guard let port = resource.port ?? (desktop ? CmuxTuiSnapshotParser.desktopPort : nil) else {
                throw SurfaceCatalogError.unsupported("browser \(resource.id) has no port")
            }
            // A forwarded-port row (`portBrowser`, id key "port:<n>") already
            // carries the URL to open — its own private address over the
            // WireGuard tunnel — and must navigate there directly, never
            // through the endpoint()/openPort proxy below: Freestyle's public
            // platform has no port-forwarding proxy for arbitrary ports, so
            // that call fails outright for exactly the machines this exists
            // for. A regular daemon browser's `url` is a different thing (the
            // remote tab's own address, not a locally-openable link) and must
            // still go through the proxy/CDP path, so this only ever fires
            // for the id shape `portBrowser` mints.
            if !desktop, resource.id.key.hasPrefix("port:"),
               let directURLString = resource.url, let directURL = URL(string: directURLString) {
                created = try SurfacePaneFactory.makeBrowserPane(url: directURL, at: destination, focus: focus)
            } else if let url = endpointURL(port: port, desktop: desktop) {
                created = try SurfacePaneFactory.makeBrowserPane(url: url, at: destination, focus: focus)
            } else {
                // Optimistic: the pane exists before its endpoint does. Minting the preview
                // token is three provider round trips, so the pane opens on a connecting
                // screen at once and navigates the moment the endpoint resolves; a failure
                // lands in the same pane as the typed error, never as a silent blank.
                let label = Self.paneLabel(machineID: machineID, port: port, desktop: desktop)
                created = try SurfacePaneFactory.makeBrowserPane(url: SurfacePaneFactory.blankURL, at: destination, focus: focus)
                SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.connecting(label), panelID: created.panelID, in: created.workspaceID)
                let pane = created
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let url = try await self.endpoint(port: port, desktop: desktop)
                        SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: url)
                    } catch {
                        let text = CloudMachineLink.errorText(error)
                        SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.failed(label, error: text), panelID: pane.panelID, in: pane.workspaceID)
                        #if DEBUG
                        cmuxDebugLog("cloud.provider.endpointFailed machine=\(self.machineID) port=\(port) error=\(String(reflecting: error))")
                        #endif
                    }
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
        catalog.upsert(resource)
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
        catalog.updateMachine(info)
        scheduleRefresh()
        return workspace
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
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
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        do {
            _ = try await link.run(arguments: CloudTuiCommandLine.renameWorkspaceArguments(
                socketPath: connected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: observed.cursor.revision
            ))
        } catch {
            // A revision can advance for an unrelated event. Retry once only
            // when this workspace still has the name we observed. If another
            // client changed it, do not overwrite that intent.
            guard Self.isRevisionConflict(error),
                  await refresh(force: true),
                  let latest = cloudState,
                  let current = latest.workspaces.first(where: { $0.id == id }),
                  current.name == previous.name else { throw error }
            let retryConnected = try await links.connected(machineID: machineID)
            guard let retryLink = await links.link(machineID: machineID) else { throw error }
            _ = try await retryLink.run(arguments: CloudTuiCommandLine.renameWorkspaceArguments(
                socketPath: retryConnected.socketPath,
                workspaceID: id,
                name: normalizedName,
                expectedRevision: latest.cursor.revision
            ))
        }
        // The command response is not the source of truth. Wait for the next
        // accepted snapshot/event so every local projection sees the same name.
        _ = await refresh(force: true)
    }

    /// Rename one placement-local daemon tab. This is the canonical path used by a
    /// cloud-tree workspace row and by a local pane that remembers its remote tab id.
    func renameRemoteTab(id: String, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalEmptyName", defaultValue: "A terminal name cannot be empty.")
            )
        }

        // Creation and rename can arrive back-to-back. Refresh before validating the
        // target, so a stale catalog can never send a tab id that no longer exists.
        guard await refresh(force: true),
              let observed = cloudState,
              let previous = observed.tabs.first(where: { $0.id == id }) else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }
        do {
            try await sendRenameTab(id: id, name: normalizedName, expectedRevision: observed.cursor.revision)
        } catch {
            guard Self.isRevisionConflict(error),
                  await refresh(force: true),
                  let latest = cloudState,
                  let current = latest.tabs.first(where: { $0.id == id }),
                  (current.name ?? "") == (previous.name ?? "") else { throw error }
            try await sendRenameTab(id: id, name: normalizedName, expectedRevision: latest.cursor.revision)
        }
        // The daemon event normally installs this before the command exits. The
        // explicit read is the barrier for older clients that do not stream deltas.
        _ = await refresh(force: true)
    }

    /// Compatibility operation for callers that intentionally mean “all views”.
    /// It is kept separate from `renameRemoteTab` so an ambiguous terminal identity
    /// can never silently rename an arbitrary placement.
    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalEmptyName", defaultValue: "A terminal name cannot be empty.")
            )
        }
        guard await refresh(force: true),
              let observed = cloudState,
              let resource = catalog.snapshot.resources(on: machine).first(where: { $0.id == id }),
              let views = resource.remoteViews,
              !views.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }

        // The daemon's tab name is placement-local. Keep one target per exact
        // tab id, and use the fresh typed state for the old value. A malformed
        // snapshot cannot make one tab run twice or make compensation restore
        // an arbitrary wire-order value.
        var seenTabIDs = Set<String>()
        let targets: [(tabID: String, previousName: String)] = views.compactMap { view in
            guard seenTabIDs.insert(view.tabID).inserted,
                  let tab = observed.tabs.first(where: { $0.id == view.tabID }) else { return nil }
            return (view.tabID, tab.name ?? "")
        }
        guard !targets.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }

        // Do not spend a revision on a view that already has the requested name.
        // This also reduces the window in which another client can race the
        // compatibility fan-out.
        let pendingTargets = targets.filter { $0.previousName != normalizedName }
        if pendingTargets.isEmpty { return }

        var lastCommitRevision = observed.cursor.revision
        var renamedTabs: [(tabID: String, previousName: String, commitRevision: UInt64)] = []
        var mutationOutcomeUncertain = false
        do {
            for target in pendingTargets {
                try Task.checkCancellation()
                do {
                    let commitRevision = try await sendRenameTab(
                        id: target.tabID,
                        name: normalizedName,
                        expectedRevision: lastCommitRevision
                    )
                    guard commitRevision >= lastCommitRevision else {
                        mutationOutcomeUncertain = true
                        throw RemoteRenameError.nonMonotonicRevision(
                            expectedAtLeast: lastCommitRevision,
                            received: commitRevision
                        )
                    }
                    renamedTabs.append((target.tabID, target.previousName, commitRevision))
                    lastCommitRevision = commitRevision
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
               latest.cursor.generation == observed.cursor.generation,
               latest.cursor.revision == lastCommitRevision,
               renamedTabs.allSatisfy({ entry in
                   latest.tabs.first(where: { $0.id == entry.tabID })?.name == normalizedName
               }) {
                compensated = true
                var compensationRevision = latest.cursor.revision
                for entry in renamedTabs.reversed() {
                    do {
                        let revision = try await sendRenameTab(
                            id: entry.tabID,
                            name: entry.previousName,
                            expectedRevision: compensationRevision
                        )
                        guard revision >= compensationRevision else {
                            compensated = false
                            break
                        }
                        compensationRevision = revision
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
    private func sendRenameTab(id: String, name: String, expectedRevision: UInt64? = nil) async throws -> UInt64 {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let data = try await link.run(arguments: CloudTuiCommandLine.renameTabArguments(
            socketPath: connected.socketPath,
            tabID: id,
            name: name,
            expectedRevision: expectedRevision
        ))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = CloudWireNumber.unsigned(object["revision"]) else {
            throw RemoteRenameError.invalidResponse
        }
        return revision
    }

    private enum RemoteRenameError: Error, LocalizedError {
        case invalidResponse
        case nonMonotonicRevision(expectedAtLeast: UInt64, received: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return String(localized: "cloudTree.error.renameTerminalResponse", defaultValue: "The remote rename response was invalid. Refresh and retry.")
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

    /// The cached endpoint for `port` as the URL a pane opens (display parameters added
    /// for the desktop), or nil when it has to be minted.
    private func endpointURL(port: Int, desktop: Bool) -> URL? {
        guard let openURL = endpoints.openURL(port: port) else { return nil }
        return URL(string: desktop ? CmuxTuiSnapshotParser.desktopURL(openURL: openURL) : openURL)
    }

    /// The endpoint for `port`, minted through the control plane on a miss and cached.
    private func endpoint(port: Int, desktop: Bool) async throws -> URL {
        if let url = endpointURL(port: port, desktop: desktop) { return url }
        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
        let minted = try await client.openPort(id: machineID, port: port)
        let raw = desktop ? CmuxTuiSnapshotParser.desktopURL(openURL: minted.openUrl) : minted.openUrl
        guard let url = URL(string: raw) else { throw ProviderError.badURL(raw) }
        endpoints.store(openURL: minted.openUrl, port: port)
        return url
    }

    /// Mints the desktop's endpoint ahead of the first drop, one flight at a time. A
    /// failure is silent here — the drop itself reports it — and retried next refresh.
    private func prefetchDesktopEndpoint() {
        let port = CmuxTuiSnapshotParser.desktopPort
        guard endpointPrefetch == nil, endpoints.openURL(port: port) == nil, VMClient.shared != nil else { return }
        endpointPrefetch = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.endpoint(port: port, desktop: true)
            self.endpointPrefetch = nil
        }
    }

    private func ports(client: VMClient, force: Bool) async -> [Int] {
        if !force, let cached = portsCache, Date().timeIntervalSince(cached.at) < portsTTL {
            return cached.ports
        }
        let command = "if command -v ss >/dev/null 2>&1; then ss -ltn; elif command -v netstat >/dev/null 2>&1; then netstat -ltn; fi"
        guard let result = try? await client.exec(id: machineID, command: command, timeoutMs: 10_000), result.exitCode == 0 else {
            return portsCache?.ports ?? []
        }
        let ports = CmuxTuiSnapshotParser.listeningPorts(fromSocketListing: result.stdout)
            .filter { !CmuxTuiSnapshotParser.internalPorts.contains($0) }
        portsCache = (ports, Date())
        return ports
    }

    private func watchChanges(link: CloudMachineLink) {
        if let watchedLink, watchedLink === link, changeWatcher != nil { return }
        changeWatcher?.cancel()
        let watcherID = UUID()
        watchedLink = link
        changeWatcherID = watcherID
        changeWatcher = Task { [weak self] in
            for await change in link.changes {
                guard let self else { return }
                await self.handle(change, from: link)
            }
            await self?.changeWatcherDidEnd(watcherID)
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
                eventsFeedWarning = nil
                clearStateRecovery()
                await link.setEventsCursor(incoming.cursor)
                await link.resumeEventsSubscription(from: incoming.cursor)
                info.linkState = .connected
                info.linkError = nil
                publish(incoming, ports: portsCache?.ports ?? [])
                reprojectRestoredPanes()
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
                cloudState = next
                cloudStateInstallVersion &+= 1
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
            if reason == "events_recovery_exhausted" {
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
        let clock = refreshClock
        stateRecoveryRefreshTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: .milliseconds(250))
            } catch {
                self?.stateRecoveryRefreshTask = nil
                return
            }
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
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.scheduledRefresh = nil
            await self.refresh(force: false)
        }
    }

    /// A restored session brings back the pane (with its UUID) but not the attach process:
    /// the catalog resolved the record into a projection whose panel is a placeholder shell.
    /// Replace it in place with a real attach pane, as a tab of the same pane, then close
    /// the placeholder.
    private func reprojectRestoredPanes() {
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
                    guard let self else { return }
                    await self.reprojectManualMirror(
                        resource: terminal,
                        projection: projection,
                        paneID: paneID
                    )
                }
            }
        }
    }
}
