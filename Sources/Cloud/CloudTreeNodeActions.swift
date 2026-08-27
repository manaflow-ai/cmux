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
    /// Close a workspace on its machine and every terminal in it.
    let closeWorkspace: @MainActor (_ machine: SurfaceMachineID, _ remoteWorkspaceID: String) -> Void
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
    /// create the cmux-tui workspace (empty, per the pointer-list model), give it a starter
    /// terminal, and open it as a new local workspace.
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
        let terminal = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: workspace.id)
        let group = SurfaceResourceGroup(title: workspace.name, resources: [terminal.id])
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
            group.resources,
            title: localWorkspaceTitle(machine: machine, group: group),
            focus: focus,
            host: .app
        )
        return (workspace, terminal, opened)
    }
}
