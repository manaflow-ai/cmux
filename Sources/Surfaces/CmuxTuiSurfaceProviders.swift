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
    private var refreshInFlight: Task<Bool, Never>?
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
    /// Returns whether the fleet list itself could be read. Refreshes never overlap: a
    /// forced refresh waits for the one in flight and then runs its own pass, so an
    /// older response can never publish over a newer one.
    @discardableResult
    func refresh(force: Bool) async -> Bool {
        // Loop, not `if`: two forced callers woken by the same finishing pass must not
        // both start a task — the second one sees the first one's task here and waits.
        while let inFlight = refreshInFlight {
            let listed = await inFlight.value
            if !force { return listed }
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performRefresh(force: force)
        }
        refreshInFlight = task
        let listed = await task.value
        if refreshInFlight == task { refreshInFlight = nil }
        return listed
    }

    func provider(machineID: String) -> CmuxTuiSurfaceProvider? {
        providers[machineID]
    }

    /// The explicit Refresh verb — the sidebar's "Refresh" and `cmux vm tree --refresh`
    /// share it: re-read the fleet (a machine created since the last poll gets its
    /// provider now instead of at the next 45 s tick), re-sync every cloud provider, then
    /// every other provider the catalog holds (this Mac).
    func refreshEverything(catalog: SurfaceCatalog) async {
        let listed = await refresh(force: true)
        // When the fleet list could not be read, nothing above ran: re-sync every
        // provider the catalog already holds instead of leaving cloud rows stale.
        let refreshedCloud = listed ? Set(providers.keys) : []
        await catalog.refreshAll(where: { machine in machine.cloudMachineID.map { !refreshedCloud.contains($0) } ?? true })
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

    private func performRefresh(force: Bool) async -> Bool {
        guard let catalog, let client = VMClient.shared else { return false }
        guard let page = try? await client.listPage() else { return false }
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
        return true
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
        case badURL(String)
        case snapshotUnreadable(String)

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
            case .snapshotUnreadable(let id):
                return String(format: String(localized: "cloud.provider.snapshotUnreadable", defaultValue: "%@'s cmux-tui session did not return a readable snapshot; retry in a moment."), id)
            }
        }
    }

    let machineID: String
    var machine: SurfaceMachineID { .cloud(machineID) }
    private(set) var info: SurfaceMachineInfo

    private var summary: VMSummary
    let links: CloudMachineLinkManager
    unowned let catalog: SurfaceCatalog
    private var changeWatcher: Task<Void, Never>?
    private var notificationWatcher: Task<Void, Never>?
    /// Bounded handoff into the notification store, shared by every machine so one consumer
    /// keeps arrival order (same shape as the ssh-tmux mirror's `paneNotificationIngress`).
    static let notificationIngress = GhosttyDesktopNotificationIngress()
    /// Admission control shared by every machine, so the fleet bucket is one bucket.
    static var notificationGate = CloudMachineNotificationGate()
    /// Daemon deltas coalesce here: one re-read in flight, at most one queued behind it.
    private lazy var refreshCoalescer = SurfaceRefreshCoalescer { [weak self] in
        await self?.refresh(force: false)
    }
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

    init(summary: VMSummary, links: CloudMachineLinkManager, catalog: SurfaceCatalog) {
        machineID = summary.id
        self.summary = summary
        self.links = links
        self.catalog = catalog
        info = Self.info(from: summary, linkState: summary.status == "running" ? .connecting : .asleep, linkError: nil, stats: nil)
    }

    var isAwake: Bool { summary.status == "running" }

    func update(summary: VMSummary) {
        self.summary = summary
        info = Self.info(from: summary, linkState: info.linkState, linkError: info.linkError, stats: nil, remoteWorkspaces: info.remoteWorkspaces)
        catalog.updateMachine(info)
    }

    func stop() {
        changeWatcher?.cancel()
        changeWatcher = nil
        notificationWatcher?.cancel()
        notificationWatcher = nil
        refreshCoalescer.cancel()
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
    func refresh(force: Bool) async {
        let machine = self.machine
        var resources: [SurfaceResource] = []
        if summary.resolvedKind.hasDesktop {
            resources.append(CmuxTuiSnapshotParser.display(machine: machine))
        }
        guard isAwake, let client = VMClient.shared else {
            info = Self.info(from: summary, linkState: .asleep, linkError: nil, stats: nil)
            catalog.replaceResources(resources, on: machine, info: info)
            return
        }
        // The display opens over the HTTPS preview and never needs the link, so a
        // machine with no resources yet gets it published before the link attempt —
        // a slow or hanging connect must not leave the desktop unopenable.
        if !resources.isEmpty, catalog.snapshot.resources(on: machine).isEmpty {
            catalog.replaceResources(resources, on: machine, info: info)
        }
        if summary.resolvedKind.hasDesktop {
            prefetchDesktopEndpoint()
        }
        async let stats = try? client.stats(id: machineID)
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        var remoteWorkspaces: [SurfaceRemoteWorkspace]?
        do {
            let (link, socketPath) = try await connectedLink(warmSnapshot: false)
            let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath))
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resources = CmuxTuiSnapshotParser.mergingDisplays(
                    pool: resources,
                    parsed: CmuxTuiSnapshotParser.terminals(fromSnapshot: object, machine: machine)
                )
                tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: object)
                remoteWorkspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: object)
            }
            let needsSurfaceIDRefresh = !manualMirrorSessions.isEmpty
                && (manualMirrorSurfaceIDsSocketPath != socketPath
                    || manualMirrorSessions.values.contains { $0.phase == .disconnected })
            var reconnectableSessionIDs = Set<ObjectIdentifier>(
                manualMirrorSessions.values.map { ObjectIdentifier($0) }
            )
            if needsSurfaceIDRefresh {
                let sessions = Array(manualMirrorSessions.values)
                let resolutions = await resolveManualMirrorSessions(
                    sessions,
                    socketPath: socketPath,
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
                    manualMirrorSurfaceIDsSocketPath = socketPath
                }
            }
            for session in manualMirrorSessions.values
            where reconnectableSessionIDs.contains(ObjectIdentifier(session)) {
                session.reconnect(socketPath: socketPath)
            }
            let privateAddress = summary.preferredPrivateAddress
            for port in await ports(client: client, force: force) {
                let directURL = privateAddress.map { CmuxInternalHostnames.directPortURL(privateAddress: $0, port: port) }
                resources.append(CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port, directURL: directURL))
            }
        } catch {
            let status = await links.status(machineID: machineID)
            linkState = status?.state ?? .error
            linkError = status?.error ?? CloudMachineLink.errorText(error)
            #if DEBUG
            cmuxDebugLog("cloud.provider.refreshFailed machine=\(machineID) state=\(linkState) error=\(String(reflecting: error))")
            #endif
        }
        info = Self.info(from: summary, linkState: linkState, linkError: linkError, stats: await stats, remoteWorkspaces: remoteWorkspaces)
        catalog.replaceResources(resources, on: machine, info: info)
        reprojectRestoredPanes()
    }

    /// The machine's link, connecting if needed — the one way every verb reaches the
    /// daemon. Whichever verb attaches first also starts the change watcher and, when
    /// the catalog has never seen this session (`remoteWorkspaces == nil`), warms the
    /// snapshot: a `vm tree` right after an attach then shows the machine's workspaces
    /// instead of `(none yet)` until the next poll or `--refresh`.
    private func connectedLink(warmSnapshot: Bool = true) async throws -> (link: CloudMachineLink, socketPath: String) {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        watchChanges(link: link)
        watchNotifications(link: link)
        if warmSnapshot, info.remoteWorkspaces == nil {
            scheduleRefresh()
        }
        return (link, connected.socketPath)
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
        return SurfaceProjection(resource: resource.id, workspaceID: created.workspaceID, panelID: created.panelID)
    }

    /// A new terminal in the machine's cmux-tui session (`workspace <ws> run -- argv`).
    /// Without `remoteWorkspaceID` it joins the machine's focused (else first) workspace;
    /// when the catalog has not synced this session yet it asks the daemon before
    /// concluding there is none, and only then creates `main`. `name` titles the
    /// terminal — it never names a workspace.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        let (link, socketPath) = try await connectedLink()
        let workspaceID: String
        if let remoteWorkspaceID = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteWorkspaceID.isEmpty {
            workspaceID = remoteWorkspaceID
        } else if let existing = Self.preferredWorkspace(knownRemoteWorkspaces()) {
            workspaceID = existing.id
        } else if let existing = Self.preferredWorkspace(try await syncRemoteWorkspaces(link: link, socketPath: socketPath)) {
            workspaceID = existing.id
        } else {
            let created = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(socketPath: socketPath, name: Self.firstWorkspaceName))
            guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
                  let id = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
                throw ProviderError.noWorkspaceOnMachine(machineID)
            }
            workspaceID = id
            // Optimistic, like `createRemoteWorkspace`: the tree shows the workspace (and
            // files the terminal under it) before the next snapshot confirms.
            recordOptimisticWorkspace(SurfaceRemoteWorkspace(id: id, name: Self.firstWorkspaceName, index: 0, focused: true))
        }
        let argv = CloudTuiCommandLine.commandStartingIn(
            cwd: cwd,
            command: (command?.isEmpty == false ? command : nil) ?? CloudTuiCommandLine.defaultTerminalCommand
        )
        let data = try await link.run(arguments: CloudTuiCommandLine.runArguments(socketPath: socketPath, workspaceID: workspaceID, command: argv))
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
            remoteWorkspace: knownRemoteWorkspaces().first { $0.id == (created.workspaceID ?? workspaceID) },
            port: nil,
            url: nil
        )
        catalog.upsert(resource)
        scheduleRefresh()
        return resource
    }

    /// The name of a workspace the provider has to create because the machine has none.
    nonisolated static let firstWorkspaceName = "main"

    /// Every workspace the catalog knows on this machine: the machine info's list (which
    /// includes empty workspaces) first, else the ones its resources point at.
    private func knownRemoteWorkspaces() -> [SurfaceRemoteWorkspace] {
        if let listed = info.remoteWorkspaces { return listed }
        var seen: Set<String> = []
        return catalog.snapshot.resources(on: machine).flatMap(\.remoteWorkspaces).filter { seen.insert($0.id).inserted }
    }

    /// Where a terminal lands when the caller names no workspace: the focused one, else
    /// the first in daemon order. Pure, shared by the create path and its tests.
    nonisolated static func preferredWorkspace(_ workspaces: [SurfaceRemoteWorkspace]) -> SurfaceRemoteWorkspace? {
        workspaces.min { ($0.focused ? 0 : 1, $0.index) < ($1.focused ? 0 : 1, $1.index) }
    }

    /// One snapshot read for the workspace list alone (no ports probe), published to the
    /// catalog so the tree reflects it too.
    private func syncRemoteWorkspaces(link: CloudMachineLink, socketPath: String) async throws -> [SurfaceRemoteWorkspace] {
        let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath))
        // A snapshot without a `workspaces` list is unreadable, not "no workspaces":
        // creating `main` on that evidence would duplicate a workspace that exists.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["workspaces"] is [[String: Any]] else {
            throw ProviderError.snapshotUnreadable(machineID)
        }
        let workspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: object)
        info.remoteWorkspaces = workspaces
        catalog.updateMachine(info)
        return workspaces
    }

    /// Show a workspace the daemon just made before its snapshot arrives.
    private func recordOptimisticWorkspace(_ workspace: SurfaceRemoteWorkspace) {
        info.remoteWorkspaces = (info.remoteWorkspaces ?? []).filter { $0.id != workspace.id } + [workspace]
        catalog.updateMachine(info)
    }

    /// A new empty workspace in the machine's cmux-tui session (`workspace create`),
    /// called directly — not as a side effect of creating a terminal.
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        let (link, socketPath) = try await connectedLink()
        // The default name counts the machine's workspaces; when the catalog has never
        // synced this session, ask the daemon first so an existing `main` is counted.
        if info.remoteWorkspaces == nil {
            _ = try await syncRemoteWorkspaces(link: link, socketPath: socketPath)
        }
        let existingCount = knownRemoteWorkspaces().count
        let workspaceName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (existingCount == 0 ? Self.firstWorkspaceName : "workspace-\(existingCount + 1)")
        let created = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(socketPath: socketPath, name: workspaceName))
        guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
              let id = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        let workspace = SurfaceRemoteWorkspace(id: id, name: workspaceName, index: existingCount, focused: false)
        // Optimistic: show the new (empty) workspace now; the next snapshot re-sync is authoritative.
        recordOptimisticWorkspace(workspace)
        scheduleRefresh()
        return workspace
    }

    func renameRemoteWorkspace(id: String, name: String) async throws {
        let (link, socketPath) = try await connectedLink()
        _ = try await link.run(arguments: CloudTuiCommandLine.renameWorkspaceArguments(socketPath: socketPath, workspaceID: id, name: name))
        info.remoteWorkspaces = info.remoteWorkspaces?.map { workspace in
            var renamed = workspace
            if workspace.id == id { renamed.name = name }
            return renamed
        }
        catalog.updateMachine(info)
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
        guard changeWatcher == nil else { return }
        changeWatcher = Task { [weak self] in
            for await _ in link.changes {
                guard let self else { return }
                self.scheduleRefresh()
            }
            await MainActor.run { [weak self] in
                self?.changeWatcher = nil
                self?.scheduleRefresh()
            }
        }
    }

    // MARK: - Notifications from the machine

    /// Notifications posted inside the machine (`cmux notify` → the daemon's ledger) arrive
    /// on the link's event stream as data. They pass the shared gate, are attributed by
    /// this Mac's catalog — the machine id is this provider's own, the terminal id is the
    /// only thing an event may name — and enter the store as a remote-origin notification:
    /// display, sound, badge, global hooks, phone forwarding; never a reply affordance, a
    /// click action, a project hook, or anything that runs on the machine's behalf.
    private func watchNotifications(link: CloudMachineLink) {
        guard notificationWatcher == nil else { return }
        notificationWatcher = Task { [weak self] in
            for await event in link.notifications {
                guard let self else { return }
                self.deliverCloudNotification(event)
            }
            await MainActor.run { [weak self] in
                self?.notificationWatcher = nil
            }
        }
    }

    private func deliverCloudNotification(_ event: CloudMachineNotificationEvent) {
        let decision = Self.notificationGate.admit(machineID: machineID, event: event)
        guard decision == .allowed else {
            Self.logNotificationDrop(machineID: machineID, reason: String(describing: decision), event: event)
            return
        }
        guard let appDelegate = AppDelegate.shared else { return }
        let target = Self.notificationTarget(
            terminalID: event.terminalID,
            machine: machine,
            projections: catalog.projections,
            isLive: { projection in
                guard let workspace = appDelegate.workspaceFor(tabId: projection.workspaceID) else { return false }
                return workspace.panels[projection.panelID] != nil
            },
            isSelectedWorkspace: { workspaceID in
                appDelegate.tabManagerFor(tabId: workspaceID)?.selectedTabId == workspaceID
            },
            isFocusedPanel: { projection in
                appDelegate.workspaceFor(tabId: projection.workspaceID)?.focusedPanelId == projection.panelID
            }
        )
        guard let target else {
            Self.logNotificationDrop(machineID: machineID, reason: "unprojected", event: event)
            return
        }
        let workspace = appDelegate.workspaceFor(tabId: target.workspaceID)
        let surfaceID: UUID? = target.panelID.map { panelID in
            workspace?.surfaceOwnershipTarget(for: panelID)?.surfaceID ?? panelID
        }
        let terminalTitle = event.terminalID.flatMap { terminalID in
            catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)]?.title
        }.flatMap { $0.isEmpty ? nil : $0 }
        let title = event.title.isEmpty ? (terminalTitle ?? info.name) : event.title
        let enqueued = Self.notificationIngress.submit(GhosttyDesktopNotificationRequest(
            tabId: target.workspaceID,
            surfaceId: surfaceID,
            // The emitter runs on the machine: never a local project-hook lookup.
            hookDirectory: nil,
            title: title,
            body: event.body,
            subtitle: info.name,
            origin: .cloudVM(machineID: machineID)
        ))
        #if DEBUG
        cmuxDebugLog(
            "cloud.notification.deliver machine=\(machineID) term=\(event.terminalID?.suffix(8) ?? "-") workspace=\(target.workspaceID.uuidString.prefix(8)) surface=\(surfaceID?.uuidString.prefix(8) ?? "nil") titleLen=\(title.count) bodyLen=\(event.body.count) enqueued=\(enqueued ? 1 : 0)"
        )
        #endif
    }

    /// Never logs title or body: they are the machine's bytes.
    private static func logNotificationDrop(machineID: String, reason: String, event: CloudMachineNotificationEvent) {
        #if DEBUG
        cmuxDebugLog(
            "cloud.notification.drop machine=\(machineID) reason=\(reason) term=\(event.terminalID?.suffix(8) ?? "-") titleLen=\(event.title.count) bodyLen=\(event.body.count)"
        )
        #endif
    }

    /// Host-owned attribution. The machine controls only the terminal id; the machine half
    /// of every key is this provider's, so an event can never reach another machine's panes,
    /// and no workspace or surface UUID is ever read from an event.
    ///
    /// 1. A projected terminal → that pane (if shown in several: the focused pane of a
    ///    selected workspace, else any selected workspace, else the catalog's own order).
    /// 2. Otherwise (session-wide, or a terminal no pane shows — a detached `cmux vm agent`
    ///    run, a pane the user closed) → a workspace-level notification wherever the user
    ///    is looking at this machine.
    /// 3. Nothing of the machine on screen → nil; the caller drops it.
    nonisolated static func notificationTarget(
        terminalID: String?,
        machine: SurfaceMachineID,
        projections: Set<SurfaceProjection>,
        isLive: (SurfaceProjection) -> Bool,
        isSelectedWorkspace: (UUID) -> Bool = { _ in false },
        isFocusedPanel: (SurfaceProjection) -> Bool = { _ in false }
    ) -> (workspaceID: UUID, panelID: UUID?)? {
        let onMachine = projections.filter { $0.resource.machine == machine && isLive($0) }
        if let terminalID {
            let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
            let candidates = Array(onMachine.filter { $0.resource == resource })
            if let chosen = primaryProjection(among: candidates, isSelectedWorkspace: isSelectedWorkspace, isFocusedPanel: isFocusedPanel) {
                return (chosen.workspaceID, chosen.panelID)
            }
        }
        guard let chosen = primaryProjection(among: Array(onMachine), isSelectedWorkspace: isSelectedWorkspace, isFocusedPanel: isFocusedPanel) else {
            return nil
        }
        return (chosen.workspaceID, nil)
    }

    private nonisolated static func primaryProjection(
        among candidates: [SurfaceProjection],
        isSelectedWorkspace: (UUID) -> Bool,
        isFocusedPanel: (SurfaceProjection) -> Bool
    ) -> SurfaceProjection? {
        let ordered = candidates.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        return ordered.first { isSelectedWorkspace($0.workspaceID) && isFocusedPanel($0) }
            ?? ordered.first { isSelectedWorkspace($0.workspaceID) }
            ?? ordered.first
    }

    /// Daemon deltas arrive in bursts; `SurfaceRefreshCoalescer` turns any number of them
    /// into at most one in-flight re-read plus one follow-up — no timers, never starved.
    func scheduleRefresh() {
        refreshCoalescer.request()
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
