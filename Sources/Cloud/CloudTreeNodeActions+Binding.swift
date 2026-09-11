import AppKit
import Foundation

/// Binds the tree's value actions to the shared catalog operation path.
extension CloudTreeNodeActions {
    @MainActor
    static func bound(
        catalog: @escaping @MainActor () -> SurfaceCatalog,
        selectedWorkspaceID: @escaping @MainActor () -> UUID?,
        selectLocalWorkspace: @escaping @MainActor (UUID) -> Void,
        onWillMutate: @escaping @MainActor (String) -> Void,
        onDidMutate: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void,
        refresh: @escaping @MainActor () -> Void,
        refreshMachine: @escaping @MainActor (SurfaceMachineID) -> Void = { _ in }, authorizeCreation: @escaping @MainActor (SurfaceMachineID) -> Bool = { _ in true }
    ) -> CloudTreeNodeActions {
        func run(_ label: String, _ operation: @escaping @MainActor (SurfaceCatalog) async throws -> Void) {
            onWillMutate(label)
            Task { @MainActor in
                do {
                    try await operation(catalog())
                } catch {
                    // Human wording first: the panel now shows this text inline, and a
                    // raw enum dump ("noProvider(cloud(\"m\"))") explains nothing there.
                    onFailure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
                }
                onDidMutate()
            }
        }
        func runCreation(_ machine: SurfaceMachineID, _ label: @autoclosure () -> String, _ operation: @escaping @MainActor (SurfaceCatalog) async throws -> Void) {
            guard authorizeCreation(machine) else { return }
            run(label()) { catalog in
                guard authorizeCreation(machine) else { return }
                try await operation(catalog)
            }
        }
        func destination(_ placement: SurfacePlacement) throws -> SurfaceDestination {
            guard let workspaceID = selectedWorkspaceID() else {
                throw SurfaceCatalogError.destinationNotFound("no selected workspace")
            }
            return .workspace(id: workspaceID, placement: placement)
        }
        // `catalog()` is a plain synchronous accessor, so resolving the
        // machine's real name is safe here even though the mutation itself
        // runs on a later Task.
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
                runCreation(machine, startingLabel(machine)) { catalog in
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
            },
            openGroup: { machine, group, placement, remoteWorkspaceID in
                if group.isEmpty {
                    runCreation(machine, startingLabel(machine)) { catalog in
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
                            focus: true
                        )
                    }
                }
            },
            openGroupAsWorkspace: { machine, group, remoteWorkspaceID in
                if group.isEmpty {
                    runCreation(machine, startingLabel(machine)) { catalog in
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
                            host: .app
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
                        // Clicking a workspace row opens its layout: the machine screen's
                        // splits, ratios and tabs, when the daemon reports them (nil → grid).
                        let layout: SurfaceProjectionLayout? = if let remoteWorkspaceID = routedGroup.remoteWorkspaceID {
                            await CloudWorkspaceLayoutTranslator.fetch(machine: machine, workspaceID: remoteWorkspaceID, catalog: catalog)
                        } else {
                            nil
                        }
                        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                            routedGroup,
                            title: Self.localWorkspaceTitle(hostName: machineName(machine), group: group),
                            focus: true,
                            host: .app,
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
                runCreation(machine, String(format: String(localized: "cloudTree.operation.newWorkspace", defaultValue: "Creating a workspace on %@\u{2026}"), machineName(machine))) { catalog in
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
                run(String(format: String(localized: "cloudTree.operation.closeWorkspace", defaultValue: "Closing %@\u{2026}"), workspace.name)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    _ = try await Self.deleteWorkspaceAndTerminals(machine: machine, provider: provider, catalog: catalog, workspaceID: workspace.id)
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
                ), name != current else { return }
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
        actions.refreshMachine = refreshMachine
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
