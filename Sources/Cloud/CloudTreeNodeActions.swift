import AppKit
import Foundation
/// Closure bundle handed to Cloud outline rows for the nodes below a machine.
struct CloudTreeNodeActions {
    /// Project a resource into the selected local workspace.
    let project: @MainActor (_ resource: SurfaceResourceID, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
    /// Project a resource while retaining the exact daemon tab placement that
    /// produced the row. This prevents a multi-view terminal from losing its
    /// rename target during materialization.
    let projectRemoteView: @MainActor (_ resource: SurfaceResourceID, _ view: SurfaceRemoteView, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
    /// Project a resource into ONE local workspace, reusing only a pane already in it
    /// (a workspace's own Desktop row: a VNC pane in another workspace neither
    /// satisfies the open nor steals focus).
    let projectInLocalWorkspace: @MainActor (_ resource: SurfaceResourceID, _ workspaceID: UUID) -> Void
    /// Project an exact remote placement into one local workspace, preserving the
    /// daemon tab identity while narrowing reuse to that workspace.
    let projectRemoteViewInLocalWorkspace: @MainActor (_ resource: SurfaceResourceID, _ view: SurfaceRemoteView, _ workspaceID: UUID) -> Void
    /// Start a plain terminal on a machine (in a cmux-tui workspace when given) and show it.
    let newTerminal: @MainActor (_ machine: SurfaceMachineID, _ remoteWorkspaceID: String?) -> Void
    /// Open a whole group (a workspace's terminals and browsers): the first at the
    /// selected workspace, the rest as tabs of that pane. An empty group starts a fresh
    /// terminal in `remoteWorkspaceID` on the machine instead.
    let openGroup: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ placement: SurfacePlacement, _ remoteWorkspaceID: String?) -> Void
    /// Open a whole group as a NEW local workspace named after it, every resource its own
    /// pane (what clicking a remote workspace row does). An empty group starts a fresh
    /// terminal in `remoteWorkspaceID` on the machine instead.
    let openGroupAsWorkspace: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ remoteWorkspaceID: String?) -> Void
    /// Create a workspace on the machine (its ⌘N: `workspace create`, then a starter
    /// terminal) and open it as a new local workspace.
    let newWorkspace: @MainActor (_ machine: SurfaceMachineID) -> Void
    /// End a terminal on its machine (the process and its remote tab).
    let closeTerminal: @MainActor (_ resource: SurfaceResourceID) -> Void
    /// Close a workspace on its machine AND kill every terminal in it (austin,
    /// 2026-08-31: a closed workspace never leaves stray terminals behind in the
    /// pool). Confirms first when there is something to kill. The protocol's
    /// keep-terminals close stays CLI-only (`cmux vm workspace close`).
    let closeWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Rename a remote workspace via a text prompt.
    let renameWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Rename a remote terminal placement via a text prompt. A nil view means the
    /// caller selected the machine pool, so the explicit compatibility operation
    /// renames all views.
    let renameTerminal: @MainActor (_ resource: SurfaceResource, _ view: SurfaceRemoteView?) -> Void
    let selectLocalWorkspace: @MainActor (_ workspaceID: UUID) -> Void
    let copyToPasteboard: @MainActor (_ text: String) -> Void
    /// Copy the machine port's private URL without changing network state.
    let copyPortLink: @MainActor (_ resource: SurfaceResourceID) -> Void
    let refresh: @MainActor () -> Void
    var refreshMachine: @MainActor (_ machine: SurfaceMachineID) -> Void = { _ in }
    var organize: @MainActor (CloudSidebarOrganizationAction, String, [CloudTreeNode]) -> Bool = { _, _, _ in false }
    /// Navigates a nested terminal through its owning Cloud workspace.
    var openRemoteTerminal: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ resource: SurfaceResourceID, _ view: SurfaceRemoteView?, _ openIn: UUID?) -> Void = { _, _, _, _, _ in }

    @MainActor
    static func bound(
        catalog: @escaping @MainActor () -> SurfaceCatalog,
        selectedWorkspaceID: @escaping @MainActor () -> UUID?,
        selectLocalWorkspace: @escaping @MainActor (UUID) -> Void,
        onWillMutate: @escaping @MainActor (String) -> Void,
        onDidMutate: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void,
        refresh: @escaping @MainActor () -> Void,
        refreshMachine: @escaping @MainActor (SurfaceMachineID) -> Void = { _ in }, operationController: CloudWorkspaceOperationController? = nil
    ) -> CloudTreeNodeActions {
        @MainActor @discardableResult
        func run(
            _ label: String,
            _ operation: @escaping @MainActor (SurfaceCatalog) async throws -> Void
        ) -> Task<Void, Never> {
            onWillMutate(label)
            return Task { @MainActor in
                defer { onDidMutate() }
                do {
                    if let recorder = AppDelegate.shared?.cloudOperations {
                        try await recorder.perform(.workspace) { try await operation(catalog()) }
                    } else {
                        try await operation(catalog())
                    }
                } catch is CancellationError {
                    // A locally admitted delete or disabled feature invalidates navigation.
                } catch {
                    onFailure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                }
            }
        }
        func destination(_ placement: SurfacePlacement) throws -> SurfaceDestination {
            guard let workspaceID = selectedWorkspaceID() else {
                throw SurfaceCatalogError.destinationNotFound("no selected workspace")
            }
            return .workspace(id: workspaceID, placement: placement)
        }
        let machineName: (SurfaceMachineID) -> String = { machine in
            Self.resolvedMachineName(machine, snapshot: catalog().snapshot)
        }
        let openingLabel: (SurfaceMachineID) -> String = { machine in
            String(format: String(localized: "cloudTree.operation.project", defaultValue: "Opening on %@\u{2026}"), machineName(machine))
        }
        let startingLabel: (SurfaceMachineID) -> String = { machine in
            String(format: String(localized: "cloudTree.operation.newTerminal", defaultValue: "Starting a terminal on %@\u{2026}"), machineName(machine))
        }
        var actions = CloudTreeNodeActions(
            project: { resource, placement, reuseExisting in
                // Capture the caller's workspace before the async operation starts.
                // Row selection and refresh notifications can otherwise change the
                // globally selected tab while a port endpoint is materializing.
                let capturedWorkspaceID = selectedWorkspaceID()
                let capturedPortWorkspaceID: UUID?
                if resource.forwardedPort != nil {
                    capturedPortWorkspaceID = catalog().preferredLocalWorkspaceID(
                        for: resource,
                        fallback: capturedWorkspaceID
                    )
                } else {
                    capturedPortWorkspaceID = nil
                }
                run(openingLabel(resource.machine)) { catalog in
                    let workspaceID: UUID
                    if resource.forwardedPort != nil {
                        guard let preferred = capturedPortWorkspaceID else {
                            throw SurfaceCatalogError.destinationNotFound(
                                SurfaceCatalog.portDestinationUnavailableMessage(machine: resource.machine)
                            )
                        }
                        workspaceID = preferred
                    } else {
                        guard let capturedWorkspaceID else {
                            throw SurfaceCatalogError.destinationNotFound("no selected workspace")
                        }
                        workspaceID = capturedWorkspaceID
                    }
                    let opened: (projection: SurfaceProjection, reused: Bool)
                    if let port = resource.forwardedPort {
                        opened = try await catalog.openCloudPort(
                            machine: resource.machine,
                            port: port,
                            into: .workspace(id: workspaceID, placement: placement),
                            focus: true,
                            reuseExisting: reuseExisting,
                            reuseInWorkspace: workspaceID
                        )
                    } else {
                        opened = try await catalog.project(
                            resource,
                            into: .workspace(id: workspaceID, placement: placement),
                            focus: true,
                            reuseExisting: reuseExisting
                        )
                    }
                    let projection = opened.projection
                    // `focus: true` above puts input focus on the created pane, but a
                    // pane opened as an additional tab does not by itself become the
                    // SELECTED tab in its column — explicitly select it too, so
                    // clicking a sidebar row always lands you looking at it.
                    SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                }
            },
            projectRemoteView: { resource, view, placement, reuseExisting in
                run(openingLabel(resource.machine)) { catalog in
                    _ = try await catalog.project(
                        resource,
                        into: try destination(placement),
                        focus: true,
                        reuseExisting: reuseExisting,
                        remoteView: view
                    )
                }
            },
            projectInLocalWorkspace: { resource, workspaceID in
                run(openingLabel(resource.machine)) { catalog in
                    if let port = resource.forwardedPort {
                        _ = try await catalog.openCloudPort(
                            machine: resource.machine,
                            port: port,
                            into: .workspace(id: workspaceID, placement: .split),
                            focus: true,
                            reuseExisting: true,
                            reuseInWorkspace: workspaceID
                        )
                    } else {
                        _ = try await catalog.project(
                            resource,
                            into: .workspace(id: workspaceID, placement: .split),
                            focus: true,
                            reuseExisting: true,
                            reuseInWorkspace: workspaceID
                        )
                    }
                }
            },
            projectRemoteViewInLocalWorkspace: { resource, view, workspaceID in
                run(openingLabel(resource.machine)) { catalog in
                    _ = try await catalog.project(
                        resource,
                        into: .workspace(id: workspaceID, placement: .split),
                        focus: true,
                        reuseExisting: true,
                        reuseInWorkspace: workspaceID,
                        remoteView: view
                    )
                }
            },
            newTerminal: { machine, remoteWorkspaceID in
                // A cloud machine gets its pane at once; the sidebar shares the
                // shortcut routes' optimistic path. The local machine and a missing
                // workspace keep the awaited create below.
                if !machine.isLocal, let workspaceID = selectedWorkspaceID(),
                   let workspace = Workspace.liveWorkspace(id: workspaceID),
                   workspace.openCloudTerminalOptimistically(on: machine, remoteWorkspaceID: remoteWorkspaceID) {
                    return
                }
                run(startingLabel(machine)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    let token = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: machine)
                    defer { catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: machine, catalog: catalog) }
                    let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                    let (projection, _) = try await catalog.project(
                        resource.id,
                        into: try destination(.tab),
                        focus: true,
                        reuseExisting: true,
                        remoteView: Self.uniqueRemoteView(resource)
                    )
                    SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                }
            },
            openGroup: { machine, group, placement, remoteWorkspaceID in
                if group.isEmpty {
                    if !machine.isLocal, let workspaceID = selectedWorkspaceID(),
                       let workspace = Workspace.liveWorkspace(id: workspaceID),
                       workspace.openCloudTerminalOptimistically(on: machine, remoteWorkspaceID: remoteWorkspaceID) {
                        return
                    }
                    run(startingLabel(machine)) { catalog in
                        if let workspaceID = remoteWorkspaceID ?? group.remoteWorkspaceID {
                            try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: workspaceID)
                        }
                        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                        let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                        let (projection, _) = try await catalog.project(
                            resource.id,
                            into: try destination(.tab),
                            focus: true,
                            reuseExisting: true,
                            remoteView: Self.uniqueRemoteView(resource)
                        )
                        SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                    }
                } else {
                    run(openingLabel(machine)) { catalog in
                        let routedGroup = group.withRemoteWorkspaceID(remoteWorkspaceID)
                        _ = try await catalog.projectGroup(
                            routedGroup,
                            into: try destination(placement),
                            focus: true,
                            optimistic: .app
                        )
                    }
                }
            },
            openGroupAsWorkspace: { machine, group, remoteWorkspaceID in
                if group.isEmpty {
                    run(startingLabel(machine)) { catalog in
                        if let workspaceID = remoteWorkspaceID ?? group.remoteWorkspaceID {
                            try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: workspaceID)
                        }
                        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                        let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                            SurfaceResourceGroup(
                                title: group.title,
                                placements: [SurfaceResourcePlacement(
                                    resource: resource.id,
                                    remoteView: Self.uniqueRemoteView(resource),
                                    remoteWorkspaceID: remoteWorkspaceID ?? group.remoteWorkspaceID
                                )],
                                remoteWorkspaceID: remoteWorkspaceID ?? group.remoteWorkspaceID
                            ),
                            title: Self.localWorkspaceTitle(hostName: machineName(machine), group: group),
                            focus: true,
                            host: .appOptimistic
                        )
                        catalog.bindCloudWorkspace(
                            localWorkspaceID: opened.workspaceID, machine: machine,
                            remoteWorkspaceID: resource.remoteWorkspace?.id ?? remoteWorkspaceID,
                            generatedTitle: Self.localWorkspaceTitle(hostName: machineName(machine), group: group)
                        )
                    }
                } else {
                    run(openingLabel(machine)) { catalog in
                        let routedGroup = group.withRemoteWorkspaceID(remoteWorkspaceID)
                        let layout: SurfaceProjectionLayout? = if let remoteWorkspaceID = routedGroup.remoteWorkspaceID {
                            await CloudWorkspaceLayoutTranslator.fetch(machine: machine, workspaceID: remoteWorkspaceID, catalog: catalog)
                        } else {
                            nil
                        }
                        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                            routedGroup,
                            title: Self.localWorkspaceTitle(hostName: machineName(machine), group: group),
                            focus: true,
                            host: .appOptimistic,
                            layout: layout
                        )
                        catalog.bindCloudWorkspace(
                            localWorkspaceID: opened.workspaceID,
                            machine: machine,
                            remoteWorkspaceID: routedGroup.remoteWorkspaceID,
                            generatedTitle: Self.localWorkspaceTitle(hostName: machineName(machine), group: group)
                        )
                    }
                }
            },
            newWorkspace: { machine in
                run(String(format: String(localized: "cloudTree.operation.newWorkspace", defaultValue: "Creating a workspace on %@\u{2026}"), machineName(machine))) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    _ = try await Self.createWorkspaceAndOpenLocally(machine: machine, provider: provider, catalog: catalog, name: nil, focus: true)
                }
            },
            closeTerminal: { resource in
                guard confirmDestructive(
                    title: String(format: String(localized: "cloudTree.killTerminal.title", defaultValue: "Kill terminal \u{201C}%@\u{201D}?"), resource.key),
                    message: String(localized: "cloudTree.killTerminal.message", defaultValue: "The process ends on the machine, everywhere it is shown. Panes keep their scrollback."),
                    verb: String(localized: "cloudTree.killTerminal.confirm", defaultValue: "Kill")
                ) else { return }
                run(String(format: String(localized: "cloudTree.operation.close", defaultValue: "Closing on %@\u{2026}"), machineName(resource.machine))) { catalog in
                    guard let provider = catalog.provider(for: resource.machine) else { throw SurfaceCatalogError.noProvider(resource.machine) }
                    try await provider.closeTerminal(resource)
                }
            },
            closeWorkspace: { machine, workspace in
                // Closing a workspace takes its terminals with it — nothing "detaches"
                // into the pool. Killing processes is the destructive part, so an
                // empty workspace closes without a prompt.
                let terminals = catalog().snapshot.resources(on: machine).filter { resource in
                    resource.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
                }
                if !terminals.isEmpty {
                    let title = String(format: String(localized: "cloudTree.closeWorkspace.title", defaultValue: "Close workspace \u{201C}%@\u{201D}?"), workspace.name)
                    let message = terminals.count == 1
                        ? String(localized: "cloudTree.closeWorkspace.message.one", defaultValue: "Its terminal is killed with it.")
                        : String(format: String(localized: "cloudTree.closeWorkspace.message.other", defaultValue: "Its %d terminals are killed with it."), terminals.count)
                    guard confirmDestructive(title: title, message: message, verb: String(localized: "cloudTree.closeWorkspace.confirm", defaultValue: "Close")) else { return }
                }
                // Admit the delete synchronously so the row is gone before the
                // first network suspension; the operation label tracks the request.
                let deletion = catalog().deleteCloudWorkspace(machine: machine, workspaceID: workspace.id)
                run(String(format: String(localized: "cloudTree.operation.closeWorkspace", defaultValue: "Closing %@\u{2026}"), workspace.name)) { _ in
                    _ = try await deletion.value
                }
            },
            renameWorkspace: { machine, workspace in
                guard let name = promptForName(
                    title: String(format: String(localized: "cloudTree.renameWorkspace.title", defaultValue: "Rename \u{201C}%@\u{201D}"), workspace.name),
                    current: workspace.name
                ), name != workspace.name else { return }
                run(String(format: String(localized: "cloudTree.operation.renameWorkspace", defaultValue: "Renaming %@\u{2026}"), workspace.name)) { catalog in
                    try await catalog.renameRemoteWorkspace(on: machine, id: workspace.id, name: name)
                }
            },
            renameTerminal: { resource, view in
                let current = view?.name ?? (resource.title.isEmpty ? resource.id.key : resource.title)
                guard let name = promptForName(
                    title: String(format: String(localized: "cloudTree.renameTerminal.title", defaultValue: "Rename \u{201C}%@\u{201D}"), current),
                    current: current,
                    allowsClear: true
                ) else { return }
                let operationLabel = name.isEmpty
                    ? String(format: String(localized: "cloudTree.operation.clearTerminal", defaultValue: "Clearing %@\u{2026}"), current)
                    : String(format: String(localized: "cloudTree.operation.renameTerminal", defaultValue: "Renaming %@\u{2026}"), current)
                run(operationLabel) { catalog in
                    if let view {
                        try await catalog.renameRemoteTab(on: resource.machine, id: view.tabID, name: name)
                    } else {
                        try await catalog.renameTerminal(on: resource.machine, id: resource.id, name: name)
                    }
                }
            },
            selectLocalWorkspace: selectLocalWorkspace,
            copyToPasteboard: Self.copyToPasteboard,
            copyPortLink: { resource in
                guard let port = resource.forwardedPort else { return }
                run(String(localized: "cloudTree.operation.copyPortLink", defaultValue: "Preparing the link\u{2026}")) { catalog in
                    guard let provider = catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider else {
                        throw SurfaceCatalogError.unsupported(SurfaceCatalog.portPreviewUnavailableMessage(machineID: resource.machine.rawValue))
                    }
                    // The same link the pane loads and `vm.port_open` reports.
                    Self.copyToPasteboard(try await provider.portLinkURL(port: port))
                }
            },
            refresh: refresh
        )
        actions.organize = { action, id, _ in catalog().organizeSidebar(action, nodeID: id) }
        actions.refreshMachine = refreshMachine
        let navigationRun: CloudTreeTerminalNavigationCoordinator.Run = run
        let navigation = CloudTreeTerminalNavigationCoordinator(
            machineName: machineName,
            run: navigationRun,
            operationController: operationController ?? AppDelegate.shared?.cloudWorkspaceOperationController
        )
        actions.openRemoteTerminal = { navigation.open(machine: $0, group: $1, resource: $2, view: $3, openIn: $4) }
        return actions
    }
    /// A create operation returns the exact tab receipt. A newly-created
    /// resource should carry that receipt into projection, while a missing or
    /// multi-view receipt must remain explicit and use catalog resolution.
    private static func uniqueRemoteView(_ resource: SurfaceResource) -> SurfaceRemoteView? {
        guard resource.remoteViews?.count == 1 else { return nil }
        return resource.remoteViews?.first
    }

    @MainActor
    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        #if DEBUG
        cmuxDebugLog("cloudTree.copyToPasteboard ok=\(ok) chars=\(text.count)")
        #endif
    }
}
