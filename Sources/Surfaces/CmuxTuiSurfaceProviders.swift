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
                // The owner normally clears the slot below, but a forced waiter
                // can resume first. Clear the completed flight while it is still
                // ours so the forced caller starts its required fresh pass instead
                // of repeatedly awaiting the same completed task.
                if refreshInFlight == inFlight {
                    refreshInFlight = nil
                }
                // A scheduled refresh can share the result. A forced caller
                // must run one fresh pass after it, but never concurrently.
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
            // `refreshGeneration` changes only when a new pass starts, and a
            // new pass cannot start until this slot is cleared. Keeping the
            // guard makes that invariant explicit for future callers.
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
        // The catalog can outlive a provider (for example a restored session
        // may have a machine row before the first fleet refresh). Reconcile
        // both stores against the authoritative list, otherwise a machine
        // deleted while cmux was closed survives as a ghost row forever.
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

    private func accessDidEnd() async {
        for provider in providers.values { provider.stop() }
        for id in providers.keys { catalog?.unregister(machine: .cloud(id)) }
        providers.removeAll()
        await links.disconnectAll()
        // Signing out drops the tunnel too: the next account enrolls its own.
        await wireGuardHub?.stop()
    }
}

/// One cloud machine's resources: its cmux-tui terminals (over the headless link), its
/// VNC display resources, and its forwarded ports. Terminals live in the machine's cmux-tui
/// session, so a local pane closing never touches them (`projectionDidEnd` is a no-op).
@MainActor
final class CmuxTuiSurfaceProvider: SurfaceProvider {
    enum ProviderError: Error, LocalizedError {
        case notSignedIn
        case machineAsleep(String)
        case noWorkspaceOnMachine(String)
        case terminalNotCreated(String)
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
    /// Incremented when the provider is stopped so suspended refresh tasks can
    /// recognize that their result belongs to a retired registration.
    private var lifecycleGeneration: UInt64 = 0
    private var changeWatcher: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    /// Invalidates an older asynchronous refresh before it can replace a newer snapshot.
    /// Registry-forced refreshes and daemon change notifications can overlap while their
    /// network/link calls are suspended; only the newest generation may publish.
    private var refreshGeneration: UInt64 = 0
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

    init(summary: VMSummary, links: CloudMachineLinkManager, catalog: SurfaceCatalog) {
        machineID = summary.id
        self.summary = summary
        self.links = links
        self.catalog = catalog
        info = Self.info(from: summary, linkState: summary.status == "running" ? .connecting : .asleep, linkError: nil, stats: nil)
    }

    var isAwake: Bool { summary.status == "running" }

    /// The catalog's shared port-open path can use either a private address or
    /// the provider's preview endpoint. Legacy providers are treated as
    /// capable until their summary advertises otherwise.
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
        info = Self.info(from: summary, linkState: info.linkState, linkError: info.linkError, stats: nil, remoteWorkspaces: info.remoteWorkspaces)
        catalog.updateMachine(info, from: self)
    }

    func stop() {
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        changeWatcher?.cancel()
        changeWatcher = nil
        refreshDebounce?.cancel()
        refreshDebounce = nil
        for session in manualMirrorSessions.values { session.stop() }
        manualMirrorSessions.removeAll()
        manualMirrorSurfaceIDsSocketPath = nil
        for task in remoteTerminalProjectionTasks.values { task.cancel() }
        remoteTerminalProjectionTasks.removeAll()
    }

    /// Whether this provider is still the catalog registration for its machine.
    /// Registry replacement can retire an instance while one of its async tasks
    /// is suspended; identity checking prevents that task from projecting panes
    /// through the replacement provider.
    func isRegisteredInCatalog() -> Bool {
        guard let current = catalog.provider(for: machine) else { return false }
        return ObjectIdentifier(current) == ObjectIdentifier(self)
    }

    /// Returns whether work started under `generation` may still mutate this
    /// provider. Stopped providers keep their object alive until registry
    /// cleanup completes, so identity alone is not sufficient.
    func isCurrentLifecycleGeneration(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
    }

    /// Returns whether a refresh belongs to this live provider registration and
    /// is still the newest refresh for it.
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
    func refresh(force: Bool) async {
        let lifecycle = lifecycleGeneration
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        let machine = self.machine
        let previousResources = catalog.snapshot.resources(on: machine)
        let preservedNonPortResources = previousResources.filter { !$0.id.isForwardedPort }
        var resources: [SurfaceResource] = []
        let privateAddress = summary.preferredPrivateAddress
        if summary.resolvedKind.hasDesktop {
            let directURL = privateAddress.map { Self.privateDesktopURL(privateAddress: $0) }
            resources.append(CmuxTuiSnapshotParser.display(machine: machine, directURL: directURL))
        }
        // Keep the last private-link scan while this refresh reconnects. A new
        // scan runs through cmux-tui after the link is ready. Routine catalog
        // refresh must never use provider exec or the web control plane.
        let scannedPorts: [Int]?
        if !supportsPortPreviews {
            // Capability removal is authoritative: stale port rows must not
            // survive a provider update that can no longer open them.
            scannedPorts = []
        } else {
            scannedPorts = portsCache?.ports
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        // A failed/incomplete port probe preserves the prior port rows; a
        // successful empty scan is authoritative and must not be repopulated
        // by the later link-failure fallback.
        var resourcesToPreserveAfterPortScan = scannedPorts == nil ? previousResources : preservedNonPortResources
        resources.append(contentsOf: Self.portResources(
            machine: machine,
            scannedPorts: scannedPorts,
            previousResources: previousResources,
            privateAddress: summary.preferredPrivateAddress
        ))
        guard isAwake, let client = VMClient.shared else {
            appendMissingResources(resourcesToPreserveAfterPortScan, to: &resources)
            info = Self.info(
                from: summary,
                linkState: .asleep,
                linkError: nil,
                stats: nil,
                remoteWorkspaces: info.remoteWorkspaces
            )
            guard catalog.replaceResources(
                catalog.preservingConcurrentPortResources(resources, on: machine, since: previousResources),
                on: machine,
                info: info,
                from: self
            ) else { return }
            return
        }
        // Publish the display before the terminal link is ready. Its private URL
        // still waits for the browser Network Extension when the user opens it.
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        if !resources.isEmpty, !catalog.hasResources(on: machine) {
            catalog.replaceResources(resources, on: machine, info: info, from: self)
        }
        async let stats = try? client.stats(id: machineID)
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        var remoteWorkspaces: [SurfaceRemoteWorkspace]? = info.remoteWorkspaces
        do {
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            let connected = try await links.connected(machineID: machineID)
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            if let refreshedPorts = await ports(
                link: link,
                socketPath: connected.socketPath,
                force: force,
                generation: generation,
                privateAddress: privateAddress
            ) {
                guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
                resources.removeAll { $0.id.isForwardedPort }
                resources.append(contentsOf: Self.portResources(
                    machine: machine,
                    scannedPorts: refreshedPorts,
                    previousResources: previousResources,
                    privateAddress: privateAddress
                ))
                resourcesToPreserveAfterPortScan = preservedNonPortResources
            }
            watchChanges(link: link, generation: lifecycle)
            let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["workspaces"] is [[String: Any]],
               object["terminals"] is [[String: Any]] {
                resources = Self.mergeSnapshotResources(
                    pool: resources,
                    parsed: CmuxTuiSnapshotParser.terminals(fromSnapshot: object, machine: machine),
                    privateAddress: summary.preferredPrivateAddress
                )
                tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: object)
                remoteWorkspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: object)
            } else {
                // A transport-level success with no session snapshot is not an
                // authoritative empty session. Keep the last resource values;
                // an explicit `{workspaces: [], terminals: []}` still clears
                // them on the next branch above.
                appendMissingResources(resourcesToPreserveAfterPortScan, to: &resources)
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
                guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
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
            // Keep cached terminal/browser rows addressable while the link is
            // reconnecting. Ports were already scanned above; this merge is
            // only for resources the failed session read could not refresh.
            appendMissingResources(resourcesToPreserveAfterPortScan, to: &resources)
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            let status = await links.status(machineID: machineID)
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
            linkState = status?.state ?? .error
            var text = status?.error ?? CloudMachineLink.errorText(error)
            linkError = text
            #if DEBUG
            cmuxDebugLog("cloud.provider.refreshFailed machine=\(machineID) state=\(linkState) error=\(String(reflecting: error))")
            #endif
        }
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        info = Self.info(from: summary, linkState: linkState, linkError: linkError, stats: await stats, remoteWorkspaces: remoteWorkspaces)
        guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        let accepted = catalog.replaceResources(
            catalog.preservingConcurrentPortResources(resources, on: machine, since: previousResources),
            on: machine,
            info: info,
            from: self
        )
        guard accepted, isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return }
        reprojectRestoredPanes(generation: lifecycle)
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

    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
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
        return SurfaceProjection(resource: resource.id, workspaceID: created.workspaceID, panelID: created.panelID)
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
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: created.terminalID),
            title: name ?? "",
            detail: cwd,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: catalog.snapshot.resources(on: machine).compactMap(\.remoteWorkspace).first { $0.id == (created.workspaceID ?? workspaceID) },
            port: nil,
            url: nil
        )
        catalog.upsert(resource, from: self)
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
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.renameWorkspaceArguments(socketPath: connected.socketPath, workspaceID: id, name: name))
        info.remoteWorkspaces = info.remoteWorkspaces?.map { workspace in
            var renamed = workspace
            if workspace.id == id { renamed.name = name }
            return renamed
        }
        catalog.updateMachine(info, from: self)
        scheduleRefresh()
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

    /// The tokened wrapper URL the control plane mints for a port; the desktop adds the
    /// noVNC query the `cmux vm desktop` recipe uses.
    /// What the connecting/failure screen calls the pane: "<machine> · Desktop" or "<machine>:<port>".
    static func paneLabel(machineID: String, port: Int, desktop: Bool) -> String {
        desktop
            ? "\(machineID) · \(String(localized: "cloudTree.node.desktop", defaultValue: "Desktop"))"
            : "\(machineID):\(port)"
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

    /// Probes the machine's listening ports. A failed probe returns nil so the
    /// caller can preserve the last complete catalog rather than treating a
    /// transient transport failure as an authoritative empty result.
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
        guard changeWatcher == nil else { return }
        guard generation == lifecycleGeneration else { return }
        changeWatcher = Task { [weak self] in
            for await _ in link.changes {
                guard let self else { return }
                guard self.lifecycleGeneration == generation else { return }
                self.scheduleRefresh()
            }
            await MainActor.run { [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.changeWatcher = nil
                self.scheduleRefresh()
            }
        }
    }

    /// Daemon deltas arrive in bursts; one re-read per burst is plenty. The delay is a
    /// deliberate coalescing window, cancelled by the next burst.
    func scheduleRefresh() {
        let generation = lifecycleGeneration
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.lifecycleGeneration == generation else { return }
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
