import AppKit
import Foundation

/// Closure bundle handed to Cloud outline rows for the nodes below a machine.
/// Bound once above the outline (never a store below it). Every open verb is
/// `SurfaceCatalog.project` — the same path the socket and `cmux vm open` use —
/// so a row, a drop, and the CLI cannot disagree about what "open" means.
struct CloudTreeNodeActions {
    /// Project a resource into the selected local workspace.
    let project: @MainActor (_ resource: SurfaceResourceID, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
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
    /// Close a workspace on its machine; its terminals detach into the pool
    /// (only `terminal close` kills content).
    let closeWorkspace: @MainActor (_ machine: SurfaceMachineID, _ remoteWorkspaceID: String) -> Void
    /// Delete a workspace AND kill every terminal in it. Confirms first.
    let deleteWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
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
                    onFailure(String(describing: error))
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
        let openingLabel: (SurfaceMachineID) -> String = { machine in
            String(format: String(localized: "cloudTree.operation.project", defaultValue: "Opening on %@\u{2026}"), machine.isLocal
                ? String(localized: "cloudTree.machine.local", defaultValue: "This Mac")
                : machine.rawValue)
        }
        let machineName: (SurfaceMachineID) -> String = { machine in
            machine.isLocal ? String(localized: "cloudTree.machine.local", defaultValue: "This Mac") : machine.rawValue
        }
        let startingLabel: (SurfaceMachineID) -> String = { machine in
            String(format: String(localized: "cloudTree.operation.newTerminal", defaultValue: "Starting a terminal on %@\u{2026}"), machine.isLocal
                ? String(localized: "cloudTree.machine.local", defaultValue: "This Mac")
                : machine.rawValue)
        }
        return CloudTreeNodeActions(
            project: { resource, placement, reuseExisting in
                run(openingLabel(resource.machine)) { catalog in
                    _ = try await catalog.project(resource, into: try destination(placement), focus: true, reuseExisting: reuseExisting)
                }
            },
            newTerminal: { machine, remoteWorkspaceID in
                run(startingLabel(machine)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                    _ = try await catalog.project(resource.id, into: try destination(.split), focus: true, reuseExisting: true)
                }
            },
            openGroup: { machine, group, placement, remoteWorkspaceID in
                if group.isEmpty {
                    run(startingLabel(machine)) { catalog in
                        guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                        let resource = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteWorkspaceID)
                        _ = try await catalog.project(resource.id, into: try destination(.split), focus: true, reuseExisting: true)
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
                            [resource.id], title: Self.localWorkspaceTitle(machine: machine, group: group), focus: true, host: .app
                        )
                    }
                } else {
                    run(openingLabel(machine)) { catalog in
                        _ = try await catalog.projectGroupAsNewLocalWorkspace(
                            group.resources, title: Self.localWorkspaceTitle(machine: machine, group: group), focus: true, host: .app
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
            closeWorkspace: { machine, remoteWorkspaceID in
                run(String(format: String(localized: "cloudTree.operation.close", defaultValue: "Closing on %@\u{2026}"), machineName(machine))) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    try await provider.closeRemoteWorkspace(id: remoteWorkspaceID)
                }
            },
            deleteWorkspace: { machine, workspace in
                let terminals = catalog().snapshot.resources(on: machine).filter { resource in
                    resource.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
                }
                let title = String(format: String(localized: "cloudTree.deleteWorkspace.title", defaultValue: "Delete workspace \u{201C}%@\u{201D}?"), workspace.name)
                let message: String
                switch terminals.count {
                case 0:
                    message = String(localized: "cloudTree.deleteWorkspace.message.empty", defaultValue: "The workspace closes on the machine.")
                case 1:
                    message = String(localized: "cloudTree.deleteWorkspace.message.one", defaultValue: "Its terminal is killed with it. To keep it, use \u{201C}Close Workspace\u{201D} instead — it moves to the Terminals pool.")
                default:
                    message = String(format: String(localized: "cloudTree.deleteWorkspace.message.other", defaultValue: "Its %d terminals are killed with it. To keep them, use \u{201C}Close Workspace\u{201D} instead — they move to the Terminals pool."), terminals.count)
                }
                guard confirmDestructive(title: title, message: message, verb: String(localized: "cloudTree.deleteWorkspace.confirm", defaultValue: "Delete")) else { return }
                run(String(format: String(localized: "cloudTree.operation.deleteWorkspace", defaultValue: "Deleting %@\u{2026}"), workspace.name)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    // Re-sync and re-enumerate AT operation time: the pre-confirm list
                    // above only words the dialog. A terminal created while the dialog
                    // was up must die with the workspace too, not detach into the pool.
                    await provider.refresh()
                    let doomed = catalog.snapshot.resources(on: machine).filter { resource in
                        resource.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
                    }
                    for terminal in doomed {
                        try await provider.closeTerminal(terminal.id)
                    }
                    try await provider.closeRemoteWorkspace(id: workspace.id)
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
                pasteboard.setString(text, forType: .string)
            },
            refresh: refresh
        )
    }

    /// "<machine>: <workspace>" — the local workspace a remote one opens as.
    static func localWorkspaceTitle(machine: SurfaceMachineID, group: SurfaceResourceGroup) -> String {
        let name = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = machine.isLocal ? String(localized: "cloudTree.machine.local", defaultValue: "This Mac") : machine.rawValue
        return name.isEmpty ? host : "\(host): \(name)"
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
            title: localWorkspaceTitle(machine: machine, group: group),
            focus: focus,
            host: .app
        )
        return (workspace, terminal, opened)
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
