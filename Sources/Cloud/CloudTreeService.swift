import AppKit
import CmuxControlSocket
import Foundation

extension Notification.Name {
    /// The Cloud tree snapshot changed (machine list, a link, or a daemon-side delta).
    /// Same name the Machines panel listens for (`CloudTreeServiceAccess.didChangeNotification`).
    static let cmuxCloudTreeDidChange = CloudTreeServiceAccess.didChangeNotification
}

/// A local terminal surface that renders one remote cmux-tui terminal.
struct CloudTerminalSurfaceBinding: Sendable, Equatable {
    let machineID: String
    let terminalID: String
}

/// The app-side owner of the Cloud tree: machines → their cmux-tui workspaces and
/// terminals, plus the synthetic Desktop and Ports nodes. The Machines panel and the
/// `vm.tree` / `vm.terminal_open` / `vm.terminal_new` / `vm.desktop_open` /
/// `vm.port_open` / `vm.link_socket` socket methods all go through this one object, so a
/// click in the sidebar and `cmux vm open …` do exactly the same thing.
///
/// Main-actor because opening things touches panes; the network and process work is
/// delegated to ``CloudMachineLinkManager`` / ``CloudMachineLink`` actors.
@MainActor
final class CloudTreeService: CloudTreeServicing {
    static let shared = CloudTreeService()

    enum ServiceError: Error, LocalizedError {
        case notSignedIn
        case machineNotFound(String)
        case machineAsleep(String)
        case workspaceNotFound(String)
        case noWorkspaceOnMachine(String)
        case terminalNotCreated(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Cloud VM access requires sign-in. Run `cmux auth login`, then retry."
            case .machineNotFound(let id):
                return "No cloud machine named \(id). Run `cmux vm ls`."
            case .machineAsleep(let id):
                return "\(id) is asleep; open it (`cmux vm shell \(id)`) to wake it before listing its terminals."
            case .workspaceNotFound(let id):
                return "Workspace \(id) was not found."
            case .noWorkspaceOnMachine(let id):
                return "\(id) has no cmux-tui workspace yet."
            case .terminalNotCreated(let detail):
                return "cmux-tui did not report the new terminal: \(detail)"
            case .openFailed(let detail):
                return detail
            }
        }
    }

    private let links: CloudMachineLinkManager
    private let paths: CloudTuiClientPaths
    private(set) var snapshot: CloudTreeSnapshot = .empty
    private var machines: [VMSummary] = []
    private var machinesFetchedAt: Date?
    private var bindings: [UUID: CloudTerminalSurfaceBinding] = [:]
    private var portsCache: [String: (ports: [CloudTreePort], at: Date)] = [:]
    private var changeWatchers: [String: Task<Void, Never>] = [:]
    private var refreshDebounce: Task<Void, Never>?
    private var accessObserver: NSObjectProtocol?

    /// How long a machine list stays fresh for a non-refresh tree read.
    private let machineListTTL: TimeInterval = 15
    private let portsTTL: TimeInterval = 30
    static let desktopPort = 6901

    init(links: CloudMachineLinkManager = CloudMachineLinkManager(), paths: CloudTuiClientPaths = CloudTuiClientPaths()) {
        self.links = links
        self.paths = paths
        accessObserver = NotificationCenter.default.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.accessDidEnd() }
        }
    }

    // MARK: - CloudTreeServicing

    func tree(machineID: String?, refresh: Bool) async throws -> CloudTreeSnapshot {
        let client = try requireClient()
        if refresh || machinesFetchedAt.map({ Date().timeIntervalSince($0) > machineListTTL }) ?? true {
            machines = try await client.listPage().vms
            machinesFetchedAt = Date()
            await links.retain(machineIDs: Set(machines.map(\.id)))
        }
        let selected = machineID.map { id in machines.filter { $0.id == id } } ?? machines
        if let machineID, selected.isEmpty {
            throw ServiceError.machineNotFound(machineID)
        }
        var built: [CloudTreeMachine] = []
        try await withThrowingTaskGroup(of: (Int, CloudTreeMachine).self) { group in
            for (index, machine) in selected.enumerated() {
                group.addTask { @MainActor in
                    (index, await self.buildMachine(machine, client: client, refresh: refresh))
                }
            }
            var indexed: [(Int, CloudTreeMachine)] = []
            for try await entry in group { indexed.append(entry) }
            built = indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let result = CloudTreeSnapshot(machines: built)
        if machineID == nil {
            snapshot = result
        } else {
            var merged = snapshot.machines.filter { $0.id != machineID }
            merged.append(contentsOf: built)
            snapshot = CloudTreeSnapshot(machines: merged)
        }
        NotificationCenter.default.post(name: .cmuxCloudTreeDidChange, object: self)
        return result
    }

    func openTerminal(
        machineID: String,
        terminalID: String,
        workspaceID: String?,
        placement: CloudTreePlacement?,
        focus: Bool
    ) async throws -> CloudTreeOpenResult {
        pruneBindings()
        if let (surfaceID, workspace) = openSurface(machineID: machineID, terminalID: terminalID) {
            if focus {
                _ = TerminalController.shared.controlSurfaceFocus(
                    routing: Self.routing(workspaceID: workspace.id),
                    surfaceID: surfaceID
                )
            }
            return CloudTreeOpenResult(surfaceID: surfaceID.uuidString, workspaceID: workspace.id.uuidString, reused: true)
        }
        let connected = try await links.connected(machineID: machineID)
        guard let clientURL = CloudTuiClientPaths.clientURL() else {
            throw CloudMachineLinkManager.ManagerError.clientMissing
        }
        let workspace = try targetWorkspace(localWorkspaceID: workspaceID, machineID: machineID)
        let command = CloudTuiCommandLine.attachShellCommand(
            clientPath: clientURL.path,
            socketPath: connected.socketPath,
            terminalID: terminalID
        )
        let surfaceID = try createTerminalSurface(in: workspace, initialCommand: command, placement: placement ?? .split, focus: focus)
        bindings[surfaceID] = CloudTerminalSurfaceBinding(machineID: machineID, terminalID: terminalID)
        markTerminalOpen(machineID: machineID, terminalID: terminalID, surfaceID: surfaceID)
        return CloudTreeOpenResult(surfaceID: surfaceID.uuidString, workspaceID: workspace.id.uuidString, reused: false)
    }

    func newTerminal(
        machineID: String,
        workspaceID: String?,
        command: [String]?,
        cwd: String?,
        name: String?,
        open: Bool
    ) async throws -> CloudTreeNewTerminalResult {
        try await newTerminal(
            machineID: machineID,
            workspaceID: workspaceID,
            command: command,
            cwd: cwd,
            name: name,
            open: open,
            localWorkspaceID: nil,
            focus: true
        )
    }

    /// `vm.terminal_new`: `workspaceID` is the REMOTE cmux-tui workspace; `localWorkspaceID`
    /// the local workspace to open into when `open` is set.
    func newTerminal(
        machineID: String,
        workspaceID: String?,
        command: [String]?,
        cwd: String?,
        name: String?,
        open: Bool,
        localWorkspaceID: String?,
        focus: Bool
    ) async throws -> CloudTreeNewTerminalResult {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ServiceError.machineAsleep(machineID)
        }
        let remoteWorkspaceID: String
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceID.isEmpty {
            remoteWorkspaceID = workspaceID
        } else {
            let workspaces = try await remoteWorkspaces(link: link, socketPath: connected.socketPath)
            if let focused = workspaces.first(where: \.focused) ?? workspaces.first {
                remoteWorkspaceID = focused.id
            } else {
                let created = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(
                    socketPath: connected.socketPath,
                    name: name ?? "main"
                ))
                guard let object = try JSONSerialization.jsonObject(with: created) as? [String: Any],
                      let path = (object["value"] as? [String: Any]) ?? Optional(object),
                      let id = path["workspace_id"] as? String ?? path["id"] as? String else {
                    throw ServiceError.noWorkspaceOnMachine(machineID)
                }
                remoteWorkspaceID = id
            }
        }
        let argv = CloudTuiCommandLine.commandStartingIn(
            cwd: cwd,
            command: (command?.isEmpty == false ? command : nil) ?? CloudTuiCommandLine.defaultTerminalCommand
        )
        let data = try await link.run(arguments: CloudTuiCommandLine.runArguments(
            socketPath: connected.socketPath,
            workspaceID: remoteWorkspaceID,
            command: argv
        ))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = CloudTreeSnapshotParser.createdTerminal(fromRunResult: object) else {
            throw ServiceError.terminalNotCreated(String(data: data, encoding: .utf8) ?? "")
        }
        scheduleRefresh(machineID: machineID)
        var surfaceID: String?
        if open {
            let opened = try await openTerminal(
                machineID: machineID,
                terminalID: created.terminalID,
                workspaceID: localWorkspaceID,
                placement: .split,
                focus: focus
            )
            surfaceID = opened.surfaceID
        }
        return CloudTreeNewTerminalResult(
            terminalID: created.terminalID,
            workspaceID: created.workspaceID ?? remoteWorkspaceID,
            surfaceID: surfaceID
        )
    }

    func openDesktop(machineID: String, workspaceID: String?, focus: Bool) async throws -> CloudTreeOpenURLResult {
        let client = try requireClient()
        let endpoint = try await client.openPort(id: machineID, port: Self.desktopPort)
        // Same recipe as `cmux vm desktop`: the noVNC page auto-connects, follows the
        // pane's size, and reconnects after a sleep.
        let url = endpoint.openUrl + "&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
        return try openBrowserSplit(url: url, machineID: machineID, localWorkspaceID: workspaceID, focus: focus)
    }

    func openPort(machineID: String, port: Int, workspaceID: String?) async throws -> CloudTreeOpenURLResult {
        let client = try requireClient()
        let endpoint = try await client.openPort(id: machineID, port: port)
        return try openBrowserSplit(url: endpoint.openUrl, machineID: machineID, localWorkspaceID: workspaceID, focus: false)
    }

    func linkSocket(machineID: String) async throws -> CloudTreeLinkSocket {
        let connected = try await links.connected(machineID: machineID)
        return CloudTreeLinkSocket(socketPath: connected.socketPath, session: connected.session)
    }

    /// The remote terminal a local surface renders, if any.
    func binding(forSurfaceID surfaceID: UUID) -> CloudTerminalSurfaceBinding? {
        bindings[surfaceID]
    }

    func machineWasDeleted(_ machineID: String) {
        Task { await links.disconnect(machineID: machineID) }
        changeWatchers[machineID]?.cancel()
        changeWatchers[machineID] = nil
        machines.removeAll { $0.id == machineID }
        snapshot = CloudTreeSnapshot(machines: snapshot.machines.filter { $0.id != machineID })
        NotificationCenter.default.post(name: .cmuxCloudTreeDidChange, object: self)
    }

    // MARK: - tree assembly

    private func buildMachine(_ machine: VMSummary, client: VMClient, refresh: Bool) async -> CloudTreeMachine {
        var node = CloudTreeMachine(
            id: machine.id,
            status: machine.status,
            image: machine.image,
            desktop: CloudTreeSnapshotParser.machineHasDesktop(image: machine.image),
            memoryMb: nil,
            diskMb: nil,
            linkState: .asleep,
            linkError: nil,
            workspaces: [],
            ports: []
        )
        guard machine.status == "running" else {
            // Never wake a sleeping machine to list it; a click on it opens (and wakes) it.
            return node
        }
        async let stats = try? client.stats(id: machine.id)
        do {
            let connected = try await links.connected(machineID: machine.id)
            guard let link = await links.link(machineID: machine.id) else { throw ServiceError.machineAsleep(machine.id) }
            watchChanges(machineID: machine.id, link: link)
            node.workspaces = try await remoteWorkspaces(link: link, socketPath: connected.socketPath)
            node.linkState = .connected
            node.ports = await ports(for: machine.id, client: client, refresh: refresh)
        } catch {
            let status = await links.status(machineID: machine.id)
            node.linkState = status?.state ?? .error
            node.linkError = status?.error ?? error.localizedDescription
        }
        if let stats = await stats {
            node.memoryMb = stats.memoryTotalMb
            node.diskMb = stats.diskTotalMb
        }
        pruneBindings()
        for (surfaceID, binding) in bindings where binding.machineID == machine.id {
            for wsIndex in node.workspaces.indices {
                for termIndex in node.workspaces[wsIndex].terminals.indices
                where node.workspaces[wsIndex].terminals[termIndex].id == binding.terminalID {
                    node.workspaces[wsIndex].terminals[termIndex].openSurfaceID = surfaceID.uuidString
                }
            }
        }
        return node
    }

    private func remoteWorkspaces(link: CloudMachineLink, socketPath: String) async throws -> [CloudTreeWorkspace] {
        let data = try await link.run(arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return CloudTreeSnapshotParser.workspaces(fromSnapshot: object)
    }

    private func ports(for machineID: String, client: VMClient, refresh: Bool) async -> [CloudTreePort] {
        if !refresh, let cached = portsCache[machineID], Date().timeIntervalSince(cached.at) < portsTTL {
            return cached.ports
        }
        let command = "if command -v ss >/dev/null 2>&1; then ss -ltn; elif command -v netstat >/dev/null 2>&1; then netstat -ltn; fi"
        guard let result = try? await client.exec(id: machineID, command: command, timeoutMs: 10_000), result.exitCode == 0 else {
            return portsCache[machineID]?.ports ?? []
        }
        let ports = CloudTreeSnapshotParser.listeningPorts(fromSocketListing: result.stdout)
            .filter { !CloudTreeSnapshotParser.internalPorts.contains($0.port) }
        portsCache[machineID] = (ports, Date())
        return ports
    }

    private func watchChanges(machineID: String, link: CloudMachineLink) {
        guard changeWatchers[machineID] == nil else { return }
        changeWatchers[machineID] = Task { [weak self] in
            for await _ in link.changes {
                guard let self else { return }
                self.scheduleRefresh(machineID: machineID)
            }
            await MainActor.run { [weak self] in
                self?.changeWatchers[machineID] = nil
                self?.scheduleRefresh(machineID: machineID)
            }
        }
    }

    /// Daemon deltas arrive in bursts; one re-read per burst is plenty for a sidebar.
    private func scheduleRefresh(machineID: String) {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            _ = try? await self.tree(machineID: machineID, refresh: false)
        }
    }

    private func accessDidEnd() async {
        await links.disconnectAll()
        for task in changeWatchers.values { task.cancel() }
        changeWatchers.removeAll()
        machines = []
        machinesFetchedAt = nil
        bindings.removeAll()
        portsCache.removeAll()
        snapshot = .empty
        NotificationCenter.default.post(name: .cmuxCloudTreeDidChange, object: self)
    }

    // MARK: - local panes

    private func requireClient() throws -> VMClient {
        guard let client = VMClient.shared else { throw ServiceError.notSignedIn }
        return client
    }

    private static func routing(workspaceID: UUID?) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
    }

    /// The local workspace to open into: the requested one, else the machine's own
    /// cmux-tui workspace, else the selected workspace of the current window.
    private func targetWorkspace(localWorkspaceID: String?, machineID: String) throws -> Workspace {
        if let raw = localWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let id = UUID(uuidString: raw),
                  let workspace = AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first(where: { $0.id == id }) else {
                throw ServiceError.workspaceNotFound(raw)
            }
            return workspace
        }
        if let bound = AppDelegate.shared?.workspace(forCloudVMID: machineID) {
            return bound
        }
        guard let workspace = TerminalController.shared.tabManager?.selectedWorkspace
            ?? AppDelegate.shared?.tabManager?.selectedWorkspace else {
            throw ServiceError.workspaceNotFound("current")
        }
        return workspace
    }

    private func createTerminalSurface(in workspace: Workspace, initialCommand: String, placement: CloudTreePlacement, focus: Bool) throws -> UUID {
        let controller = TerminalController.shared
        let routing = Self.routing(workspaceID: workspace.id)
        switch placement {
        case .tab:
            let resolution = controller.controlSurfaceCreate(
                routing: routing,
                inputs: ControlSurfaceCreateInputs(
                    typeRaw: "terminal",
                    providerRaw: nil,
                    rendererRaw: nil,
                    urlRaw: nil,
                    workingDirectory: nil,
                    initialCommand: initialCommand,
                    tmuxStartCommand: nil,
                    remotePTYSessionID: nil,
                    remoteContextRaw: nil,
                    startupEnvironment: [:],
                    requestedPaneID: nil,
                    requestedFocus: focus
                )
            )
            if case .created(_, _, _, let surfaceID, _) = resolution { return surfaceID }
            throw ServiceError.openFailed("Could not open a terminal tab for the remote terminal (\(resolution)).")
        case .split, .pane:
            let resolution = controller.controlSurfaceSplit(
                routing: routing,
                inputs: ControlSurfaceSplitInputs(
                    directionRaw: "right",
                    typeRaw: "terminal",
                    urlRaw: nil,
                    requestedSourceSurfaceID: nil,
                    workingDirectory: nil,
                    initialCommand: initialCommand,
                    tmuxStartCommand: nil,
                    remotePTYSessionID: nil,
                    remoteContextRaw: nil,
                    startupEnvironment: [:],
                    clientUnsupportedRemoteTmuxOptions: [],
                    requestedFocus: focus,
                    initialDividerPosition: nil
                )
            )
            if case .created(_, _, _, let surfaceID, _) = resolution { return surfaceID }
            throw ServiceError.openFailed("Could not split a pane for the remote terminal (\(resolution)).")
        }
    }

    private func openBrowserSplit(url: String, machineID: String, localWorkspaceID: String?, focus: Bool) throws -> CloudTreeOpenURLResult {
        let workspace = try targetWorkspace(localWorkspaceID: localWorkspaceID, machineID: machineID)
        var params: [String: Any] = ["url": url, "workspace_id": workspace.id.uuidString, "focus": focus]
        if let surfaceID = workspace.focusedPanelId {
            params["surface_id"] = surfaceID.uuidString
        }
        let result = TerminalController.shared.v2BrowserOpenSplit(params: params, diffViewerRegistration: .notNeeded)
        switch result {
        case .ok(let payload):
            let dictionary = payload as? [String: Any] ?? [:]
            let surfaceID = (dictionary["surface_id"] as? String)
                ?? (dictionary["browser_surface_id"] as? String)
                ?? (dictionary["panel_id"] as? String)
                ?? ""
            return CloudTreeOpenURLResult(surfaceID: surfaceID, url: url)
        case .err(_, let message, _):
            throw ServiceError.openFailed(message)
        }
    }

    private func openSurface(machineID: String, terminalID: String) -> (UUID, Workspace)? {
        for (surfaceID, binding) in bindings
        where binding.machineID == machineID && binding.terminalID == terminalID {
            if let workspace = AppDelegate.shared?.workspace(containingSurfaceID: surfaceID) {
                return (surfaceID, workspace)
            }
        }
        return nil
    }

    private func markTerminalOpen(machineID: String, terminalID: String, surfaceID: UUID) {
        var machines = snapshot.machines
        for m in machines.indices where machines[m].id == machineID {
            for w in machines[m].workspaces.indices {
                for t in machines[m].workspaces[w].terminals.indices
                where machines[m].workspaces[w].terminals[t].id == terminalID {
                    machines[m].workspaces[w].terminals[t].openSurfaceID = surfaceID.uuidString
                }
            }
        }
        snapshot = CloudTreeSnapshot(machines: machines)
        NotificationCenter.default.post(name: .cmuxCloudTreeDidChange, object: self)
    }

    /// Drops bindings whose local surface is gone (pane closed).
    private func pruneBindings() {
        bindings = bindings.filter { AppDelegate.shared?.workspace(containingSurfaceID: $0.key) != nil }
    }
}
