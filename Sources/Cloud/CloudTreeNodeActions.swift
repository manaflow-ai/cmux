import AppKit
import Foundation

/// Closure bundle handed to Cloud outline rows for the nodes below a machine.
/// Bound once above the outline (never a store below it). Every open verb is
/// `SurfaceCatalog.project` — the same path the socket and `cmux vm open` use —
/// so a row, a drop, and the CLI cannot disagree about what "open" means.
struct CloudTreeNodeActions {
    /// Project a resource into the selected local workspace.
    let project: @MainActor (_ resource: SurfaceResourceID, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
    /// Project a resource into ONE local workspace, reusing only a pane already in it
    /// (a workspace's own Desktop row: a VNC pane in another workspace neither
    /// satisfies the open nor steals focus).
    let projectInLocalWorkspace: @MainActor (_ resource: SurfaceResourceID, _ workspaceID: UUID) -> Void
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
    /// Select a local workspace.
    let selectLocalWorkspace: @MainActor (_ workspaceID: UUID) -> Void
    let copyToPasteboard: @MainActor (_ text: String) -> Void
    let refresh: @MainActor () -> Void

    @MainActor
    static func bound(
        catalog: @escaping @MainActor () -> SurfaceCatalog,
        selectedWorkspaceID: @escaping @MainActor () -> UUID?,
        selectLocalWorkspace: @escaping @MainActor (UUID) -> Void,
        onWillMutate: @escaping @MainActor (String) -> Void,
        onDidMutate: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void,
        refresh: @escaping @MainActor () -> Void
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
        return CloudTreeNodeActions(
            project: { resource, placement, reuseExisting in
                run(openingLabel(resource.machine)) { catalog in
                    let (projection, _) = try await catalog.project(resource, into: try destination(placement), focus: true, reuseExisting: reuseExisting)
                    // `focus: true` above puts input focus on the created pane, but a
                    // pane opened as an additional tab does not by itself become the
                    // SELECTED tab in its column — explicitly select it too, so
                    // clicking a sidebar row always lands you looking at it.
                    SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                }
            },
            projectInLocalWorkspace: { resource, workspaceID in
                run(openingLabel(resource.machine)) { catalog in
                    _ = try await catalog.project(
                        resource,
                        into: .workspace(id: workspaceID, placement: .split),
                        focus: true,
                        reuseExisting: true,
                        reuseInWorkspace: workspaceID
                    )
                }
            },
            newTerminal: { machine, remoteWorkspaceID in
                run(startingLabel(machine)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                    let (projection, _) = try await catalog.project(resource.id, into: try destination(.tab), focus: true, reuseExisting: true)
                    SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                }
            },
            openGroup: { machine, group, placement, remoteWorkspaceID in
                if group.isEmpty {
                    run(startingLabel(machine)) { catalog in
                        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                        let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                        let (projection, _) = try await catalog.project(resource.id, into: try destination(.tab), focus: true, reuseExisting: true)
                    SurfacePaneFactory.focus(panelID: projection.panelID, in: projection.workspaceID)
                    }
                } else {
                    run(openingLabel(machine)) { catalog in
                        _ = try await catalog.projectGroup(group.resources, into: try destination(placement), focus: true)
                    }
                }
            },
            openGroupAsWorkspace: { machine, group, remoteWorkspaceID in
                if group.isEmpty {
                    run(startingLabel(machine)) { catalog in
                        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                        let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                        _ = try await catalog.projectGroupAsNewLocalWorkspace(
                            [resource.id], title: Self.localWorkspaceTitle(hostName: machineName(machine), group: group), focus: true, host: .app
                        )
                    }
                } else {
                    run(openingLabel(machine)) { catalog in
                        _ = try await catalog.projectGroupAsNewLocalWorkspace(
                            group.resources, title: Self.localWorkspaceTitle(hostName: machineName(machine), group: group), focus: true, host: .app
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
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    try await provider.renameRemoteWorkspace(id: workspace.id, name: name)
                }
            },
            selectLocalWorkspace: selectLocalWorkspace,
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let ok = pasteboard.setString(text, forType: .string)
                #if DEBUG
                cmuxDebugLog("cloudTree.copyToPasteboard ok=\(ok) chars=\(text.count)")
                #endif
            },
            refresh: refresh
        )
    }

    /// The local workspace's title: the remote workspace's own name — what a
    /// person actually named it, or typed into its terminal — never the
    /// machine's raw provider id. `hostName` (the machine's friendly label)
    /// only shows up when the workspace itself has no name to show.
    static func localWorkspaceTitle(hostName: String, group: SurfaceResourceGroup) -> String {
        let name = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? hostName : name
    }

    /// The machine's friendly label — `SurfaceMachineInfo.name` (the same
    /// preferred name its own sidebar row shows), never the raw provider VM
    /// id. Shared by every caller that needs a machine's name in
    /// user-visible text (progress labels, a compound workspace title).
    static func resolvedMachineName(_ machine: SurfaceMachineID, snapshot: SurfaceCatalogSnapshot) -> String {
        if machine.isLocal { return String(localized: "cloudTree.machine.local", defaultValue: "This Mac") }
        let name = snapshot.machines.first(where: { $0.id == machine })?.name
        return name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : machine.rawValue
    }

    /// The machine's ⌘N, shared by the sidebar's ＋ and the socket's `vm.workspace_new`:
    /// create the cmux-tui workspace, give it a starter terminal, and open it as a new
    /// local workspace. The daemon may attach its own starter to a created workspace
    /// (older cmux-tui builds do), so an existing terminal is reused before a second one
    /// is created — ⌘N must yield exactly one pane.
    @MainActor
    static func createWorkspaceAndOpenLocally(
        machine: SurfaceMachineID,
        provider: any SurfaceProvider,
        catalog: SurfaceCatalog,
        name: String?,
        focus: Bool
    ) async throws -> (
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource,
        opened: (workspaceID: UUID, projections: [SurfaceProjection])
    ) {
        let workspace = try await provider.createRemoteWorkspace(name: name)
        await provider.refresh()
        let existing = catalog.snapshot.resources(on: machine).first { resource in
            resource.id.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
        }
        let terminal: SurfaceResource
        if let existing {
            terminal = existing
        } else {
            terminal = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: workspace.id)
        }
        let group = SurfaceResourceGroup(title: workspace.name, resources: [terminal.id])
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
            group.resources,
            title: localWorkspaceTitle(hostName: resolvedMachineName(machine, snapshot: catalog.snapshot), group: group),
            focus: focus,
            host: .app
        )
        return (workspace, terminal, opened)
    }

    /// The full close, shared by the sidebar's "Close Workspace…" (menu and hover ×) and
    /// the socket's `vm.workspace_delete`: kill every terminal viewed in the workspace,
    /// then close the workspace. Re-syncs and re-enumerates AT operation time — the
    /// sidebar's pre-confirm list only words its dialog; a terminal created while the
    /// dialog was up must die with the workspace too, never linger in the pool. Returns
    /// how many terminals were closed. (Plain `closeRemoteWorkspace` is the protocol's
    /// keep-terminals close, reachable only from the CLI / `vm.workspace_close`.)
    @MainActor
    @discardableResult
    static func deleteWorkspaceAndTerminals(
        machine: SurfaceMachineID,
        provider: any SurfaceProvider,
        catalog: SurfaceCatalog,
        workspaceID: String
    ) async throws -> Int {
        await provider.refresh()
        let doomed = catalog.snapshot.resources(on: machine).filter { resource in
            resource.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspaceID }
        }
        for terminal in doomed {
            try await provider.closeTerminal(terminal.id)
        }
        try await provider.closeRemoteWorkspace(id: workspaceID)
        return doomed.count
    }

    /// The house destructive-confirm shape (`NSAlert`, warning style, verb first).
    @MainActor
    private static func confirmDestructive(title: String, message: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: String(localized: "cloudTree.confirm.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A one-field rename prompt. Returns the trimmed name, or nil on cancel/empty.
    @MainActor
    private static func promptForName(title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "cloudTree.rename.confirm", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "cloudTree.confirm.cancel", defaultValue: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
