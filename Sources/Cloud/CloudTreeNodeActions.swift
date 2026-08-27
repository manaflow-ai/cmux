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
    /// Kill a terminal or browser (the content, not a view). Confirms first.
    let killResource: @MainActor (_ resource: SurfaceResource) -> Void
    /// Close a remote workspace; its terminals detach into the pool. No confirm.
    let closeWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Delete a remote workspace AND kill its terminals. Confirms first.
    let deleteWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Rename a remote workspace via a text prompt.
    let renameWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void

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
            refresh: refresh,
            killResource: { resource in
                let name = resource.title.isEmpty ? resource.id.key : resource.title
                let title = resource.id.kind == .browser
                    ? String(format: String(localized: "cloudTree.killBrowser.title", defaultValue: "Close browser \u{201C}%@\u{201D}?"), name)
                    : String(format: String(localized: "cloudTree.killTerminal.title", defaultValue: "Kill terminal \u{201C}%@\u{201D}?"), name)
                let message = resource.id.kind == .browser
                    ? String(localized: "cloudTree.killBrowser.message", defaultValue: "The page closes on the machine, everywhere it is shown.")
                    : String(localized: "cloudTree.killTerminal.message", defaultValue: "The process ends on the machine, everywhere it is shown. Panes keep their scrollback.")
                guard confirmDestructive(title: title, message: message, verb: String(localized: "cloudTree.killTerminal.confirm", defaultValue: "Kill")) else { return }
                run(String(format: String(localized: "cloudTree.operation.kill", defaultValue: "Closing %@\u{2026}"), name)) { catalog in
                    guard let provider = catalog.provider(for: resource.machine) else { throw SurfaceCatalogError.noProvider(resource.machine) }
                    try await provider.closeResource(resource.id)
                }
            },
            closeWorkspace: { machine, workspace in
                run(String(format: String(localized: "cloudTree.operation.closeWorkspace", defaultValue: "Closing %@\u{2026}"), workspace.name)) { catalog in
                    guard let provider = catalog.provider(for: machine) else { throw SurfaceCatalogError.noProvider(machine) }
                    try await provider.closeRemoteWorkspace(id: workspace.id)
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
                    for terminal in terminals {
                        try await provider.closeResource(terminal.id)
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
            }
        )
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
