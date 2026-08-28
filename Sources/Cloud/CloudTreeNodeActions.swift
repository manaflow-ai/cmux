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
    /// Create a new, empty cmux-tui workspace on a machine — the direct `workspace create`
    /// path, not the create-a-terminal fallback.
    let newWorkspace: @MainActor (_ machine: SurfaceMachineID) -> Void
    /// Open a whole group (a workspace's terminals and browsers): the first at the
    /// selected workspace, the rest as tabs of that pane. An empty group starts a fresh
    /// terminal in `remoteWorkspaceID` on the machine instead.
    let openGroup: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ placement: SurfacePlacement, _ remoteWorkspaceID: String?) -> Void
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
            newWorkspace: { machine in
                let label = String(format: String(localized: "cloudTree.operation.newWorkspace", defaultValue: "Creating a workspace on %@\u{2026}"), machine.isLocal
                    ? String(localized: "cloudTree.machine.local", defaultValue: "This Mac")
                    : machine.rawValue)
                run(label) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    _ = try await provider.createRemoteWorkspace(name: nil)
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
            selectLocalWorkspace: selectLocalWorkspace,
            copyToPasteboard: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            },
            refresh: refresh
        )
    }
}
