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
    private var refreshInFlight: Task<Void, Never>?
    /// Same cadence as the Machines panel's list refresh.
    private let pollInterval: Duration = .seconds(45)

    init(links: CloudMachineLinkManager = CloudMachineLinkManager()) {
        self.links = links
    }

    /// Registers this Mac's cloud machines with the catalog and starts polling.
    func start(catalog: SurfaceCatalog) {
        self.catalog = catalog
        accessObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.accessDidEnd() }
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
    private let links: CloudMachineLinkManager
    private unowned let catalog: SurfaceCatalog
    private var changeWatcher: Task<Void, Never>?
    private var refreshDebounce: Task<Void, Never>?
    private var portsCache: (ports: [Int], at: Date)?
    private let portsTTL: TimeInterval = 30
    /// Panels this provider created (or replaced) in this process. A projection whose
    /// panel is not here came back from a restored session as a placeholder shell.
    private var materializedPanels: Set<UUID> = []
    /// Terminal → tab from the last snapshot, so an exited terminal (whose own selector
    /// no longer resolves in cmux-tui) can still be closed through its tab.
    private var tabByTerminal: [String: String] = [:]

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
        refreshDebounce?.cancel()
        refreshDebounce = nil
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
        if CmuxTuiSnapshotParser.machineHasDesktop(image: summary.image) {
            resources.append(CmuxTuiSnapshotParser.display(machine: machine))
        }
        guard isAwake, let client = VMClient.shared else {
            info = Self.info(from: summary, linkState: .asleep, linkError: nil, stats: nil)
            catalog.replaceResources(resources, on: machine, info: info)
            return
        }
        async let stats = try? client.stats(id: machineID)
        var linkState: SurfaceLinkState = .connected
        var linkError: String?
        var remoteWorkspaces: [SurfaceRemoteWorkspace]?
        do {
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            watchChanges(link: link)
            let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath))
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resources += CmuxTuiSnapshotParser.terminals(fromSnapshot: object, machine: machine)
                tabByTerminal = CmuxTuiSnapshotParser.tabByTerminal(fromSnapshot: object)
                remoteWorkspaces = CmuxTuiSnapshotParser.workspaces(fromSnapshot: object)
            }
            for port in await ports(client: client, force: force) {
                resources.append(CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port))
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

    /// `terminal <id> close`; a terminal whose process already exited is gone from
    /// cmux-tui's selectors, so its tab is closed instead. Either way the resource
    /// leaves the catalog now and the next snapshot confirms.
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        do {
            _ = try await link.run(arguments: CloudTuiCommandLine.closeTerminalArguments(socketPath: connected.socketPath, terminalID: id.key))
        } catch {
            guard let tabID = tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await link.run(arguments: CloudTuiCommandLine.closeTabArguments(socketPath: connected.socketPath, tabID: tabID))
        }
        catalog.remove(id)
        scheduleRefresh()
    }

    /// `workspace <id> close`: its tabs go with it. A terminal also viewed from another
    /// workspace survives (pointer-list model); one viewed only here is removed
    /// optimistically, and the next snapshot is authoritative.
    func closeRemoteWorkspace(id: String) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(arguments: CloudTuiCommandLine.closeWorkspaceArguments(socketPath: connected.socketPath, workspaceID: id))
        for resource in catalog.snapshot.resources(on: machine) {
            let views = resource.remoteWorkspaces
            guard !views.isEmpty, views.allSatisfy({ $0.id == id }) else { continue }
            catalog.remove(resource.id)
        }
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
            let command = try await attachCommand(terminalID: resource.id.key)
            created = try SurfacePaneFactory.makeTerminalPane(initialCommand: command, workingDirectory: nil, at: destination, focus: focus)
        case .display:
            let url = try await browserURL(port: resource.port ?? CmuxTuiSnapshotParser.desktopPort, desktop: true)
            created = try SurfacePaneFactory.makeBrowserPane(url: url, at: destination, focus: focus)
        case .browser:
            guard let port = resource.port else { throw SurfaceCatalogError.unsupported("browser \(resource.id) has no port") }
            let url = try await browserURL(port: port, desktop: false)
            created = try SurfacePaneFactory.makeBrowserPane(url: url, at: destination, focus: focus)
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

    /// The terminal lives in the machine's session; only the local pane went away.
    func projectionDidEnd(_ projection: SurfaceProjection) {
        materializedPanels.remove(projection.panelID)
    }

    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        materializedPanels.remove(projection.panelID)
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
            hasDesktop: CmuxTuiSnapshotParser.machineHasDesktop(image: summary.image),
            memoryMb: stats?.memoryTotalMb,
            diskMb: stats?.diskTotalMb,
            linkState: linkState,
            linkError: linkError,
            cpuPercent: stats?.cpuPercent,
            memoryUsedMb: stats?.memoryUsedMb,
            diskUsedMb: stats?.diskUsedMb,
            remoteWorkspaces: remoteWorkspaces
        )
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
    private func browserURL(port: Int, desktop: Bool) async throws -> URL {
        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
        let endpoint = try await client.openPort(id: machineID, port: port)
        let raw = desktop ? CmuxTuiSnapshotParser.desktopURL(openURL: endpoint.openUrl) : endpoint.openUrl
        guard let url = URL(string: raw) else { throw ProviderError.badURL(raw) }
        return url
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

    /// Daemon deltas arrive in bursts; one re-read per burst is plenty. The delay is a
    /// deliberate coalescing window, cancelled by the next burst.
    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
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
                    do {
                        let command = try await self.attachCommand(terminalID: terminal.id.key)
                        let created = try SurfacePaneFactory.makeTerminalPane(
                            initialCommand: command,
                            workingDirectory: nil,
                            at: .tab(workspaceID: projection.workspaceID, paneID: paneID, index: nil),
                            focus: false
                        )
                        self.materializedPanels.insert(created.panelID)
                        self.catalog.endProjections(panelID: projection.panelID)
                        self.catalog.record(SurfaceProjection(resource: terminal.id, workspaceID: created.workspaceID, panelID: created.panelID))
                        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
                    } catch {
                        self.materializedPanels.remove(projection.panelID)
                    }
                }
            }
        }
    }
}
