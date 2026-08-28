import CmuxControlSocket
import Foundation

// The socket face of the surface catalog: `surface.catalog`, `surface.project`,
// `surface.new_terminal`, and the `vm.tree` / `vm.terminal_open` / `vm.terminal_new` /
// `vm.desktop_open` / `vm.port_open` / `vm.link_socket` verbs that are now thin wrappers
// over the same catalog. Every entrypoint (sidebar, CLI, agents) opens a surface through
// `SurfaceCatalog.project`, so "is it open?" and "where does it land?" have one answer.
//
// Lane (ControlCommandExecutionPolicy): socket worker. These await main-actor catalog work
// that can sit on the network (a cloud provider materializing a pane), so they must never
// hold the main actor; `v2VmCall` parks the worker while the catalog runs on the main actor.
// Focus policy: `focus` defaults to true for explicit opens (the caller asked for a pane)
// and false for desktop/port opens; the catalog never activates the app either way.
extension TerminalController {
    nonisolated func socketWorkerSurfaceResponse(method: String, id: Any?, params: [String: Any]) -> String {
        switch method {
        case "surface.catalog":
            let machine = Self.surfaceMachineFilter(params["machine"])
            let refresh = Self.surfaceBool(params["refresh"]) ?? false
            return v2VmCall(id: id, timeoutSeconds: 120) {
                if refresh {
                    await SurfaceCatalog.shared.refreshAll()
                }
                let snapshot = await SurfaceCatalog.shared.snapshot
                return Self.surfaceCatalogPayload(snapshot, machine: machine)
            }

        case "surface.project":
            guard let raw = Self.surfaceString(params["resource"]), let resource = SurfaceResourceID(rawValue: raw) else {
                return v2Error(id: id, code: "invalid_params", message: "surface.project requires `resource` (an id from `cmux surface ls --json`, e.g. vivid-newt/terminal/term_…).")
            }
            let focus = Self.surfaceBool(params["focus"]) ?? true
            let reuse = Self.surfaceBool(params["reuse"]) ?? true
            guard let workspaceID = surfaceTargetWorkspaceID(params) else {
                return v2Error(id: id, code: "invalid_params", message: "surface.project: no target workspace (pass `workspace_id`, or select one).")
            }
            let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
            return v2VmCall(id: id, timeoutSeconds: 180) {
                let opened = try await SurfaceCatalog.shared.project(resource, into: destination, focus: focus, reuseExisting: reuse)
                return Self.surfaceProjectPayload(opened.projection, reused: opened.reused)
            }

        case "surface.new_terminal":
            guard let machineRaw = Self.surfaceString(params["machine"]), !machineRaw.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "surface.new_terminal requires `machine` (\"local\" or a cloud machine id).")
            }
            let machine = SurfaceMachineID(rawValue: machineRaw)
            let command = Self.surfaceStringArray(params["command"])
            let cwd = Self.surfaceString(params["cwd"])
            let name = Self.surfaceString(params["name"])
            let remoteWorkspaceID = Self.surfaceString(params["remote_workspace_id"])
            let open = Self.surfaceBool(params["open"]) ?? true
            let focus = Self.surfaceBool(params["focus"]) ?? true
            let workspaceID = open ? surfaceTargetWorkspaceID(params) : nil
            if open, workspaceID == nil {
                return v2Error(id: id, code: "invalid_params", message: "surface.new_terminal: no target workspace to open into (pass `workspace_id`, select one, or send `open: false`).")
            }
            let destination = workspaceID.map { Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: $0) }
            return v2VmCall(id: id, timeoutSeconds: 240) {
                try await Self.surfaceNewTerminal(
                    machine: machine,
                    command: command.isEmpty ? nil : command,
                    cwd: cwd,
                    name: name,
                    remoteWorkspaceID: remoteWorkspaceID,
                    destination: destination,
                    focus: focus
                )
            }

        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    // MARK: - vm.* wrappers (kept for existing callers; same catalog underneath)

    /// `vm.tree {id?, refresh?}`: the catalog payload restricted to cloud machines.
    nonisolated func socketWorkerVMTreeResponse(id: Any?, params: [String: Any]) -> String {
        let vmId = Self.surfaceString(params["id"]) ?? Self.surfaceString(params["machine"])
        let refresh = Self.surfaceBool(params["refresh"]) ?? false
        return v2VmCall(id: id, timeoutSeconds: 120) {
            if refresh {
                await SurfaceCatalog.shared.refreshAll()
            }
            let snapshot = await SurfaceCatalog.shared.snapshot
            return Self.surfaceCatalogPayload(snapshot, machine: vmId.map { .cloud($0) }, cloudOnly: true)
        }
    }

    /// `vm.terminal_open {id, terminal_id, workspace_id?, placement?, focus?, pane_id?, direction?, tab_index?}`
    /// → `{surface_id, workspace_id, reused}`.
    nonisolated func socketWorkerVMTerminalOpenResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_open requires `id`. Run `cmux vm tree` to find one.")
        }
        guard let terminalId = Self.surfaceString(params["terminal_id"]), !terminalId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_open requires `terminal_id` (a `term_…` id from `cmux vm tree`).")
        }
        let resource = SurfaceResourceID(machine: .cloud(vmId), kind: .terminal, key: terminalId)
        let focus = Self.surfaceBool(params["focus"]) ?? true
        guard let workspaceID = surfaceTargetWorkspaceID(params) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_open: no target workspace (pass `workspace_id`, or select one).")
        }
        let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
        return v2VmCall(id: id, timeoutSeconds: 180) {
            let opened = try await SurfaceCatalog.shared.project(resource, into: destination, focus: focus, reuseExisting: true)
            return Self.surfaceProjectPayload(opened.projection, reused: opened.reused)
        }
    }

    /// `vm.terminal_new {id, workspace_id?: ws_… (remote), command?, cwd?, name?, open?, local_workspace_id?, focus?, …dest}`
    /// → `{terminal_id, workspace_id (remote ws_…), surface_id?, resource}`.
    nonisolated func socketWorkerVMTerminalNewResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_new requires `id`. Run `cmux vm ls` to find one.")
        }
        let remoteWorkspaceID = Self.surfaceString(params["workspace_id"])
        let command = Self.surfaceStringArray(params["command"])
        let cwd = Self.surfaceString(params["cwd"])
        let name = Self.surfaceString(params["name"])
        let open = Self.surfaceBool(params["open"]) ?? true
        let focus = Self.surfaceBool(params["focus"]) ?? true
        // The legacy shape names the local target `local_workspace_id`; the catalog shape
        // uses `workspace_id` for it. Map before resolving.
        var targetParams = params
        targetParams["workspace_id"] = params["local_workspace_id"]
        let workspaceID = open ? surfaceTargetWorkspaceID(targetParams) : nil
        if open, workspaceID == nil {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_new: no local workspace to open into (pass `local_workspace_id`, select one, or send `open: false`).")
        }
        let destination = workspaceID.map { Self.surfaceDestination(surfaceResolvedParams(targetParams), workspaceID: $0) }
        return v2VmCall(id: id, timeoutSeconds: 240) {
            var payload = try await Self.surfaceNewTerminal(
                machine: .cloud(vmId),
                command: command.isEmpty ? nil : command,
                cwd: cwd,
                name: name,
                remoteWorkspaceID: remoteWorkspaceID,
                destination: destination,
                focus: focus
            )
            // Legacy result: `workspace_id` is the REMOTE workspace here.
            payload["local_workspace_id"] = payload["workspace_id"] ?? NSNull()
            payload["workspace_id"] = payload["remote_workspace_id"] ?? NSNull()
            return payload
        }
    }

    /// `vm.desktop_open {id, workspace_id?, focus?, …dest}` → `{surface_id, workspace_id, url, open_url}`;
    /// an empty object when the machine has no desktop.
    nonisolated func socketWorkerVMDesktopOpenResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.desktop_open requires `id`. Run `cmux vm ls` to find one.")
        }
        let resource = SurfaceResourceID(machine: .cloud(vmId), kind: .display, key: SurfaceResourceID.desktopDisplayKey)
        let focus = Self.surfaceBool(params["focus"]) ?? false
        guard let workspaceID = surfaceTargetWorkspaceID(params) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.desktop_open: no target workspace (pass `workspace_id`, or select one).")
        }
        let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
        return v2VmCall(id: id, timeoutSeconds: 180) {
            do {
                let opened = try await SurfaceCatalog.shared.project(resource, into: destination, focus: focus, reuseExisting: false)
                var payload = Self.surfaceProjectPayload(opened.projection, reused: opened.reused)
                let url = await SurfaceCatalog.shared.resources[resource]?.url ?? ""
                payload["url"] = url
                payload["open_url"] = url
                return payload
            } catch SurfaceCatalogError.unknownResource {
                // No screen on this machine (shell-only image): the CLI renders the
                // friendly "no desktop" line when `surface_id` is absent.
                return [:]
            }
        }
    }

    /// `vm.port_open {id, port, workspace_id?, …dest}` → `{surface_id, workspace_id, url, open_url}`.
    nonisolated func socketWorkerVMPortOpenResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.port_open requires `id`. Run `cmux vm ls` to find one.")
        }
        guard let port = Self.surfaceInt(params["port"]), (1...65535).contains(port) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.port_open requires `port` between 1 and 65535. From the CLI, use `cmux vm open <id> <port>`.")
        }
        let resource = SurfaceResourceID(machine: .cloud(vmId), kind: .browser, key: SurfaceResourceID.portKey(port))
        let focus = Self.surfaceBool(params["focus"]) ?? false
        guard let workspaceID = surfaceTargetWorkspaceID(params) else {
            return v2Error(id: id, code: "invalid_params", message: "vm.port_open: no target workspace (pass `workspace_id`, or select one).")
        }
        let destination = Self.surfaceDestination(surfaceResolvedParams(params), workspaceID: workspaceID)
        return v2VmCall(id: id, timeoutSeconds: 180) {
            let catalog = await SurfaceCatalog.shared
            if await catalog.resources[resource] == nil {
                // Ports are discovered by probing the machine; a port the person names may
                // not have been seen yet. Re-sync THIS machine (a fleet-wide forced refresh
                // waits on every other machine's link too), then register it so the
                // provider can open it.
                if let provider = await CmuxTuiSurfaceProviderRegistry.shared.provider(machineID: vmId) {
                    await provider.refresh(force: true)
                } else {
                    await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true)
                }
                if await catalog.resources[resource] == nil {
                    await catalog.upsert(SurfaceResource(
                        id: resource,
                        title: ":\(port)",
                        detail: nil,
                        lifecycle: .running,
                        agent: nil,
                        remoteWorkspace: nil,
                        port: port,
                        url: nil
                    ))
                }
            }
            let opened = try await catalog.project(resource, into: destination, focus: focus, reuseExisting: false)
            var payload = Self.surfaceProjectPayload(opened.projection, reused: opened.reused)
            let url = await catalog.resources[resource]?.url ?? ""
            payload["url"] = url
            payload["open_url"] = url
            return payload
        }
    }

    /// `vm.link_socket {id}` → `{socket_path, session}`.
    nonisolated func socketWorkerVMLinkSocketResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.link_socket requires `id`. Run `cmux vm ls` to find one.")
        }
        return v2VmCall(id: id, timeoutSeconds: 120) {
            let link = try await CmuxTuiSurfaceProviderRegistry.shared.linkSocketPath(machineID: vmId)
            return ["socket_path": link.socketPath, "session": link.session]
        }
    }

    /// `vm.workspace_new {id, name?, focus?}` → creates a cmux-tui workspace on the machine
    /// (its ⌘N: `workspace create`, then a starter terminal) and opens it as a new local
    /// workspace: `{remote_workspace_id, terminal_id, workspace_id, surface_id}`. The
    /// sidebar's "New Workspace" runs the same shared path.
    nonisolated func socketWorkerVMWorkspaceNewResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.workspace_new requires `id`. Run `cmux vm ls` to find one.")
        }
        let name = Self.surfaceString(params["name"])
        return v2VmCall(id: id, timeoutSeconds: 240) {
            let machine = SurfaceMachineID.cloud(vmId)
            let catalog = await SurfaceCatalog.shared
            guard let provider = try await Self.surfaceProvider(for: machine, catalog: catalog) else {
                throw SurfaceCatalogError.noProvider(machine)
            }
            let created = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: machine,
                provider: provider,
                catalog: catalog,
                name: name,
                focus: Self.surfaceBool(params["focus"]) ?? true
            )
            return [
                "machine": machine.rawValue,
                "remote_workspace_id": created.workspace.id,
                "remote_workspace_name": created.workspace.name,
                "terminal_id": created.terminal.id.key,
                "workspace_id": created.opened.workspaceID.uuidString,
                "surface_id": created.opened.projections.first?.panelID.uuidString ?? NSNull(),
            ]
        }
    }

    /// `vm.workspace_open {id, workspace_id}` → the remote workspace's terminals and browsers
    /// as a new local workspace, every one its own pane (what clicking the row does).
    nonisolated func socketWorkerVMWorkspaceOpenResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.workspace_open requires `id`.")
        }
        guard let remoteWorkspaceID = Self.surfaceString(params["workspace_id"]), !remoteWorkspaceID.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.workspace_open requires `workspace_id` (a cmux-tui workspace id from `cmux vm tree`).")
        }
        return v2VmCall(id: id, timeoutSeconds: 240) {
            let machine = SurfaceMachineID.cloud(vmId)
            let catalog = await SurfaceCatalog.shared
            let resources = await catalog.snapshot.resources(on: machine).filter { $0.remoteWorkspace?.id == remoteWorkspaceID }
            guard let workspace = resources.first?.remoteWorkspace else {
                throw SurfaceCatalogError.destinationNotFound("workspace \(remoteWorkspaceID) on \(vmId)")
            }
            let group = SurfaceResourceGroup(title: workspace.name, resources: resources.map(\.id))
            let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                group.resources,
                title: CloudTreeNodeActions.localWorkspaceTitle(machine: machine, group: group),
                focus: Self.surfaceBool(params["focus"]) ?? true,
                host: .app
            )
            return [
                "machine": machine.rawValue,
                "remote_workspace_id": remoteWorkspaceID,
                "workspace_id": opened.workspaceID.uuidString,
                "surface_ids": opened.projections.map { $0.panelID.uuidString },
                "opened": opened.projections.count,
            ]
        }
    }

    /// `vm.workspace_close {id, workspace_id}` → closes the cmux-tui workspace and its terminals.
    nonisolated func socketWorkerVMWorkspaceCloseResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty,
              let remoteWorkspaceID = Self.surfaceString(params["workspace_id"]), !remoteWorkspaceID.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.workspace_close requires `id` and `workspace_id`.")
        }
        return v2VmCall(id: id, timeoutSeconds: 120) {
            let machine = SurfaceMachineID.cloud(vmId)
            let catalog = await SurfaceCatalog.shared
            guard let provider = try await Self.surfaceProvider(for: machine, catalog: catalog) else {
                throw SurfaceCatalogError.noProvider(machine)
            }
            try await provider.closeRemoteWorkspace(id: remoteWorkspaceID)
            return ["machine": machine.rawValue, "remote_workspace_id": remoteWorkspaceID, "closed": true]
        }
    }

    /// `vm.terminal_close {id, terminal_id}` → ends that terminal on the machine.
    nonisolated func socketWorkerVMTerminalCloseResponse(id: Any?, params: [String: Any]) -> String {
        guard let vmId = Self.surfaceString(params["id"]), !vmId.isEmpty,
              let terminalID = Self.surfaceString(params["terminal_id"]), !terminalID.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "vm.terminal_close requires `id` and `terminal_id`.")
        }
        return v2VmCall(id: id, timeoutSeconds: 120) {
            let machine = SurfaceMachineID.cloud(vmId)
            let catalog = await SurfaceCatalog.shared
            guard let provider = try await Self.surfaceProvider(for: machine, catalog: catalog) else {
                throw SurfaceCatalogError.noProvider(machine)
            }
            try await provider.closeTerminal(SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID))
            return ["machine": machine.rawValue, "terminal_id": terminalID, "closed": true]
        }
    }

    // MARK: - Shared pieces

    /// The catalog's provider for `machine`; a cloud machine the catalog has not seen yet
    /// (just created) gets one fleet re-read before the caller reports "no provider".
    nonisolated static func surfaceProvider(for machine: SurfaceMachineID, catalog: SurfaceCatalog) async throws -> (any SurfaceProvider)? {
        if let provider = await catalog.provider(for: machine) { return provider }
        guard case .cloud(let machineID) = machine else { return nil }
        _ = await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: machineID)
        return await catalog.provider(for: machine)
    }

    /// Creates a terminal on `machine` through its provider and, when a destination is given,
    /// projects it there. Payload: `resource`, `terminal_id` (the provider key), `machine`,
    /// `remote_workspace_id`, and — when opened — `workspace_id` (local) + `surface_id`.
    nonisolated static func surfaceNewTerminal(
        machine: SurfaceMachineID,
        command: [String]?,
        cwd: String?,
        name: String?,
        remoteWorkspaceID: String?,
        destination: SurfaceDestination?,
        focus: Bool
    ) async throws -> [String: Any] {
        let catalog = await SurfaceCatalog.shared
        guard let provider = try await Self.surfaceProvider(for: machine, catalog: catalog) else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        let resource = try await provider.createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID)
        var payload: [String: Any] = [
            "resource": resource.id.rawValue,
            "terminal_id": resource.id.key,
            "machine": machine.rawValue,
            "remote_workspace_id": resource.remoteWorkspace?.id ?? NSNull(),
        ]
        if let destination {
            let opened = try await catalog.project(resource.id, into: destination, focus: focus, reuseExisting: false)
            payload["workspace_id"] = opened.projection.workspaceID.uuidString
            payload["surface_id"] = opened.projection.panelID.uuidString
        }
        return payload
    }

    /// The local workspace an open lands in: `workspace_id` (UUID or `workspace:N` ref), else
    /// the workspace of a given `pane_id`/`surface_id`, else the selected workspace.
    nonisolated func surfaceTargetWorkspaceID(_ params: [String: Any]) -> UUID? {
        if let explicit = v2UUID(params, "workspace_id") {
            return explicit
        }
        if let paneID = v2UUID(params, "pane_id"), let located = v2MainSync({ self.v2LocatePane(paneID) }) {
            return located.workspace.id
        }
        if let surfaceID = v2UUID(params, "surface_id") {
            let owner = v2MainSync { () -> UUID? in
                guard let tabManager = self.tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.panels[surfaceID] != nil })?.id
            }
            if let owner { return owner }
        }
        return v2MainSync { self.tabManager?.selectedTabId }
    }

    /// `pane_id` / `surface_id` may be UUIDs or handle refs (`pane:3`, `surface:7`); the pure
    /// destination mapper needs pane UUIDs, so resolve refs here and turn a surface into the
    /// pane that holds it.
    nonisolated func surfaceResolvedParams(_ params: [String: Any]) -> [String: Any] {
        var resolved = params
        if let paneID = v2UUID(params, "pane_id") {
            resolved["pane_id"] = paneID.uuidString
        }
        if resolved["pane_id"] == nil, let surfaceID = v2UUID(params, "surface_id") {
            let paneID = v2MainSync { () -> String? in
                guard let tabManager = self.tabManager,
                      let workspace = tabManager.tabs.first(where: { $0.panels[surfaceID] != nil }) else { return nil }
                return SurfacePaneFactory.paneID(ofPanel: surfaceID, in: workspace.id)
            }
            if let paneID {
                resolved["pane_id"] = paneID
                resolved["surface_id"] = nil
            }
        }
        return resolved
    }

    /// Destination from the shared params: `pane_id` + `direction` → split that pane on that
    /// side; `pane_id` + `tab_index` (or `placement: tab`) → a tab in that pane; otherwise the
    /// workspace's focused pane (`placement`, default split). Pure.
    nonisolated static func surfaceDestination(_ params: [String: Any], workspaceID: UUID) -> SurfaceDestination {
        let paneID = surfaceString(params["pane_id"]) ?? surfaceString(params["surface_id"])
        let placement = surfaceString(params["placement"]).flatMap { SurfacePlacement(rawValue: $0.lowercased()) } ?? .split
        let direction = surfaceString(params["direction"]).flatMap { SurfaceSplitDirection(rawValue: $0.lowercased()) }
        let tabIndex = surfaceInt(params["tab_index"])
        if let paneID, let direction {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: direction)
        }
        if let paneID, tabIndex != nil || placement == .tab {
            return .tab(workspaceID: workspaceID, paneID: paneID, index: tabIndex)
        }
        if let paneID {
            return .split(workspaceID: workspaceID, paneID: paneID, direction: .right)
        }
        return .workspace(id: workspaceID, placement: placement)
    }

    nonisolated static func surfaceMachineFilter(_ raw: Any?) -> SurfaceMachineID? {
        guard let value = surfaceString(raw), !value.isEmpty else { return nil }
        return SurfaceMachineID(rawValue: value)
    }

    // MARK: Wire payloads (snake_case; the same shape the CLI and the sidebar read)

    nonisolated static func surfaceCatalogPayload(_ snapshot: SurfaceCatalogSnapshot, machine: SurfaceMachineID?, cloudOnly: Bool = false) -> [String: Any] {
        let machines = snapshot.machines.filter { info in
            if cloudOnly, info.id.isLocal { return false }
            if let machine { return info.id == machine }
            return true
        }
        let included = Set(machines.map { $0.id })
        let resources = snapshot.resources.filter { included.contains($0.machine) }
        let resourceIDs = Set(resources.map { $0.id })
        let projections = snapshot.projections.filter { resourceIDs.contains($0.resource) }
        var openPanels: [SurfaceResourceID: [SurfaceProjection]] = [:]
        for projection in projections {
            openPanels[projection.resource, default: []].append(projection)
        }
        return [
            "machines": machines.map(surfaceMachinePayload),
            "resources": resources.map { surfaceResourcePayload($0, projections: openPanels[$0.id] ?? []) },
            "projections": projections.map(surfaceProjectionPayload),
        ]
    }

    nonisolated static func surfaceMachinePayload(_ info: SurfaceMachineInfo) -> [String: Any] {
        [
            "id": info.id.rawValue,
            "local": info.id.isLocal,
            "name": info.name,
            "status": info.status,
            "image": info.image ?? NSNull(),
            "has_desktop": info.hasDesktop,
            "memory_mb": info.memoryMb ?? NSNull(),
            "disk_mb": info.diskMb ?? NSNull(),
            "link_state": info.linkState.rawValue,
            "link_error": info.linkError ?? NSNull(),
            "cpu_percent": info.cpuPercent ?? NSNull(),
            "memory_used_mb": info.memoryUsedMb ?? NSNull(),
            "disk_used_mb": info.diskUsedMb ?? NSNull(),
            "remote_workspaces": info.remoteWorkspaces.map { $0.map(surfaceRemoteWorkspacePayload) } ?? NSNull(),
        ]
    }

    nonisolated static func surfaceResourcePayload(_ resource: SurfaceResource, projections: [SurfaceProjection]) -> [String: Any] {
        var payload: [String: Any] = [
            "id": resource.id.rawValue,
            "machine": resource.machine.rawValue,
            "kind": resource.kind.rawValue,
            "key": resource.id.key,
            "title": resource.title,
            "detail": resource.detail ?? NSNull(),
            "lifecycle": resource.lifecycle.rawValue,
            "port": resource.port ?? NSNull(),
            "url": resource.url ?? NSNull(),
            "open": !projections.isEmpty,
            "open_surface_ids": projections.map { $0.panelID.uuidString },
            "open_workspace_ids": projections.map { $0.workspaceID.uuidString },
        ]
        if let agent = resource.agent {
            payload["agent"] = ["state": agent.state, "source": agent.source ?? NSNull()] as [String: Any]
        } else {
            payload["agent"] = NSNull()
        }
        if let workspace = resource.remoteWorkspace {
            payload["remote_workspace"] = surfaceRemoteWorkspacePayload(workspace)
        } else {
            payload["remote_workspace"] = NSNull()
        }
        // All views of the resource (one per daemon tab). null = the provider does not
        // model views; [] = alive with zero views (the machine's pool).
        if let views = resource.remoteViews {
            payload["view_count"] = views.count
            payload["remote_views"] = views.map { view in
                ["tab_id": view.tabID, "workspace": surfaceRemoteWorkspacePayload(view.workspace)] as [String: Any]
            }
        } else {
            payload["view_count"] = NSNull()
            payload["remote_views"] = NSNull()
        }
        return payload
    }

    nonisolated static func surfaceRemoteWorkspacePayload(_ workspace: SurfaceRemoteWorkspace) -> [String: Any] {
        [
            "id": workspace.id,
            "name": workspace.name,
            "index": workspace.index,
            "focused": workspace.focused,
        ]
    }

    nonisolated static func surfaceProjectionPayload(_ projection: SurfaceProjection) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "surface_id": projection.panelID.uuidString,
        ]
    }

    nonisolated static func surfaceProjectPayload(_ projection: SurfaceProjection, reused: Bool) -> [String: Any] {
        [
            "resource": projection.resource.rawValue,
            "workspace_id": projection.workspaceID.uuidString,
            "surface_id": projection.panelID.uuidString,
            "panel_id": projection.panelID.uuidString,
            "reused": reused,
        ]
    }

    // MARK: Param helpers (nonisolated; the worker parses before hopping to the main actor)

    nonisolated static func surfaceString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func surfaceBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    nonisolated static func surfaceInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    nonisolated static func surfaceStringArray(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { surfaceString($0) }
    }
}

extension SurfaceResourceID {
    /// The key every provider uses for a machine's one VNC display (T10 makes this a list).
    static let desktopDisplayKey = "display:1"

    /// The key for the browser that shows a forwarded HTTP port.
    static func portKey(_ port: Int) -> String { "port:\(port)" }
}
