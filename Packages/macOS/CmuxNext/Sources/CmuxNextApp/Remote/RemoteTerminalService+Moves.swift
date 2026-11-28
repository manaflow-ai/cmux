import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Moves across sessions (plans/cmux-next/data-model.md 1.5): they move
/// references, never processes. A terminal tab of session S moved into a
/// workspace homed on H becomes a remote-terminal tab on H; a remote
/// reference moved into a workspace homed on its terminal's session becomes
/// a plain terminal tab again (`terminal.project`).
extension RemoteTerminalService {
    /// The pane a moved or opened tab lands in: the workspace's first
    /// screen's default pane, else its first pane.
    static func landingPane(in workspace: WorkspaceModel) -> PaneModel? {
        guard let screen = workspace.screens.first else { return nil }
        return screen.defaultPane.flatMap(screen.pane) ?? screen.panes.first
    }

    /// Moves `tab` from `source` into `workspace` on `destination` (another
    /// session). `completion` gets whether it moved.
    func move(_ tab: TabModel, from source: DaemonService, to workspace: WorkspaceModel, on destination: DaemonService,
              completion: @escaping (Bool) -> Void) {
        let registry = services.registry
        guard tab.kind != .browser else {
            registry.refuse(RemoteStrings.moveBrowserAcrossMachines)
            return completion(false)
        }
        guard let target = Self.landingPane(in: workspace) else {
            // An empty workspace (no pane yet) cannot hold the tab.
            registry.refuse(RefusalStrings.noPaneID(workspace.displayName))
            return completion(false)
        }
        guard let sourceConnection = source.connection, let destinationConnection = destination.connection else {
            registry.refuse(WorkspaceVerbStrings.machineNotConnected)
            return completion(false)
        }
        let targetHandle = target.handle
        let surface = tab.surface
        let title = tab.displayTitle.isEmpty ? nil : tab.displayTitle
        if tab.kind == .remoteTerminal, let ref = tab.remote, destination.identity?.sessionID == ref.sessionID {
            // Home again: a plain terminal tab on its own session.
            guard let path = resourcePath(of: target, in: workspace) else { return completion(false) }
            let known = resource(for: ref, on: destination)
            let index = target.tabs.count
            let name = tab.name
            registry.track(Task { [weak self] in
                do {
                    var resource = known
                    if resource == nil { resource = try await destinationConnection.keepTerminal(ref.terminalID) }
                    guard let resource else {
                        completion(false)
                        return ActionWorkFailure(RemoteStrings.machineHasNoTerminal)
                    }
                    _ = try await destinationConnection.projectTerminal(resource, into: path, index: index, name: name)
                    _ = try? await destinationConnection.setTerminalKeep(.terminal(ref.terminalID), keep: false)
                    try await sourceConnection.closeTab(surface)
                    self?.forget(tabID: tab.id)
                    completion(true)
                    return nil
                } catch {
                    completion(false)
                    return ActionWorkFailure("move terminal home", error)
                }
            })
            return
        }
        guard destination.supports(DaemonCapabilities.shared.remoteTerminalTabs) else {
            registry.refuse(RemoteStrings.needsRemoteTerminalTabs)
            return completion(false)
        }
        // The terminal's session and id: a remote reference keeps pointing
        // at the same terminal; a plain tab's terminal runs on `source`.
        let ref: RemoteTerminalRef
        let resource: ResourceID?
        if tab.kind == .remoteTerminal, let existing = tab.remote {
            ref = existing
            resource = nil
        } else if let terminal = tab.terminalID, let session = source.identity?.sessionID {
            ref = RemoteTerminalRef(sessionID: session, terminalID: terminal, sessionName: sessionName(of: source))
            resource = tab.terminalResourceID
        } else {
            return completion(false)
        }
        let terminalConnection = tab.kind == .remoteTerminal ? services.machines.daemon(session: ref.sessionID)?.connection : sourceConnection
        registry.track(Task { [weak self] in
            do {
                // Kept first: closing the old tab must never end it.
                let kept = try? await terminalConnection?.keepTerminal(ref.terminalID)
                if let known = kept ?? resource { self?.remember(ref, resource: known) }
                _ = try await destinationConnection.newRemoteTerminalTab(ref, in: targetHandle, title: title)
                try await sourceConnection.closeTab(surface)
                self?.forget(tabID: tab.id)
                completion(true)
                return nil
            } catch {
                completion(false)
                return ActionWorkFailure("move terminal to another machine", error)
            }
        })
    }

    /// A new terminal on `machine` shown as a remote-terminal tab in
    /// `pane` (whose workspace is homed on `home`). The terminal has no tab
    /// on `machine`: `create-terminal {detached}` (`detached-terminals-v1`),
    /// else created in one of the machine's workspaces (a scratch one when
    /// it has none) and that tab closed.
    func openTerminal(on machine: DaemonService, in pane: PaneModel, home: DaemonService, cwd: String?) -> ActionWorkFailure? {
        // Only the tab's session stores the reference; the terminal's session
        // needs no new capability.
        guard home.supports(DaemonCapabilities.shared.remoteTerminalTabs) else {
            return ActionWorkFailure(RemoteStrings.needsRemoteTerminalTabs)
        }
        guard let machineConnection = machine.connection, let homeConnection = home.connection,
              let session = machine.identity?.sessionID else { return ActionWorkFailure(WorkspaceVerbStrings.machineNotConnected) }
        let name = sessionName(of: machine)
        let paneHandle = pane.handle
        let detached = machine.supports(DaemonCapabilities.shared.detachedTerminals)
        let existing = machine.store.workspaces.first { $0.key != nil }?.key
        services.registry.track(Task { [weak self] in
            do {
                let terminal: TerminalID
                let resource: ResourceID?
                if detached {
                    let created = try await machineConnection.createDetachedTerminal(cwd: cwd)
                    (terminal, resource) = (created.terminalID, created.terminalResourceID)
                } else {
                    var key = existing
                    var scratch: WorkspaceKey?
                    if key == nil {
                        let created = try await machineConnection.createWorkspace(name: name)
                        (key, scratch) = (created.key, created.key)
                    }
                    guard let key else { return ActionWorkFailure("open terminal on machine: no workspace") }
                    (terminal, resource) = try await machineConnection.createUnplacedTerminal(in: key, cwd: cwd)
                    if let scratch { _ = try? await machineConnection.closeWorkspace(scratch) }
                }
                let ref = RemoteTerminalRef(sessionID: session, terminalID: terminal, sessionName: name)
                if let resource { self?.remember(ref, resource: resource) }
                _ = try await homeConnection.newRemoteTerminalTab(ref, in: paneHandle, title: RemoteStrings.terminalOn(name))
                return nil
            } catch {
                return ActionWorkFailure("open terminal on machine", error)
            }
        })
        return nil
    }

    /// The name stored on a reference (the placeholder label while the
    /// session is away).
    func sessionName(of daemon: DaemonService) -> String {
        if daemon.isLocal { return daemon.identity?.machineName ?? MacName.kernelHostName() }
        return services.machines.machineName(daemon.machineID) ?? daemon.identity?.machineName ?? daemon.identity?.session ?? daemon.machineID
    }

    private func resourcePath(of pane: PaneModel, in workspace: WorkspaceModel) -> PaneResourcePath? {
        guard let screen = workspace.screens.first(where: { $0.panes.contains { $0 === pane } }),
              let workspaceID = workspace.resourceID, let screenID = screen.resourceID, let paneID = pane.resourceID else { return nil }
        return PaneResourcePath(workspace: workspaceID, screen: screenID, pane: paneID)
    }
}
