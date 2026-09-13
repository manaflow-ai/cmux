import AppKit
import Bonsplit
import Foundation

/// Identifies one remote workspace placement for a local projection.
struct CloudWorkspaceRemoteIdentity: Hashable, Sendable {
    let machine: SurfaceMachineID
    let workspaceID: String
}

/// Supplies the application lookups needed by cloud rename reconciliation.
///
/// The closures keep the rename service independent from the app delegate. Tests can
/// provide an isolated registry, while the composition root supplies the live one.
struct CloudWorkspaceRenameEnvironment {
    let workspace: @MainActor (UUID) -> Workspace?
    let tabManager: @MainActor (UUID) -> TabManager?
    let workspaces: @MainActor () -> [Workspace]

    init(
        workspace: @escaping @MainActor (UUID) -> Workspace? = { _ in nil },
        tabManager: @escaping @MainActor (UUID) -> TabManager? = { _ in nil },
        workspaces: @escaping @MainActor () -> [Workspace] = { [] }
    ) {
        self.workspace = workspace
        self.tabManager = tabManager
        self.workspaces = workspaces
    }
}

/// Owns cloud rename policy and the application-side write-through lifecycle.
///
/// The service is constructed by the app composition root and passed to the surface
/// catalog. It has no process-wide mutable state. The catalog remains the owner of
/// remote ordering and accepted cloud snapshots; this service only resolves local
/// owners, applies titles, and submits intents through that catalog.
final class CloudWorkspaceRenameService {
    let environment: CloudWorkspaceRenameEnvironment

    init(environment: CloudWorkspaceRenameEnvironment = CloudWorkspaceRenameEnvironment()) {
        self.environment = environment
    }
    /// A local workspace can be automatically associated with a remote workspace only
    /// when all identity-bearing panes prove the same cloud identity and no local pane
    /// is present. A mixed local/cloud workspace is intentionally left unbound: there
    /// is no honest remote owner for its title, and guessing would rename the wrong VM.
    /// The caller supplies one resource index, shared across batch reconciliation.
    func inferredRemoteWorkspaceTarget(
        projections: [SurfaceProjection],
        resourcesByID: [SurfaceResourceID: SurfaceResource]
    ) -> (machine: SurfaceMachineID, remoteWorkspaceID: String)? {
        guard !projections.isEmpty else { return nil }
        var targets = Set<CloudWorkspaceRemoteIdentity>()
        for projection in projections {
            guard !projection.resource.machine.isLocal,
                  let resource = resourcesByID[projection.resource] else { return nil }
            let remoteID: String?
            if let explicit = projection.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                remoteID = explicit
            } else if resource.remoteWorkspaces.isEmpty || (resource.kind == .display && projection.remoteTabID == nil) {
                // A cloud display, port browser, or pool terminal may be projected
                // without a daemon-workspace placement. It cannot establish a target,
                // but it also cannot contradict an exact terminal/workspace anchor.
                continue
            } else {
                let candidates = Set(resource.remoteWorkspaces.map(\.id))
                guard candidates.count == 1 else { return nil }
                remoteID = candidates.first
            }
            guard let remoteID, !remoteID.isEmpty else { return nil }
            targets.insert(CloudWorkspaceRemoteIdentity(
                machine: projection.resource.machine,
                workspaceID: remoteID
            ))
        }
        guard targets.count == 1, let target = targets.first else { return nil }
        return (target.machine, target.workspaceID)
    }

    /// Fills a missing remote workspace id after any projection lifecycle operation.
    /// An existing non-empty binding remains authoritative because it may be an explicit
    /// `workspace.cloud_vm_bind` choice. This helper only adds information; it never
    /// replaces a deliberate binding or clears state during a temporary disconnect.
    @MainActor
    func reconcileBinding(localWorkspaceID: UUID, catalog: SurfaceCatalog) {
        guard let workspace = environment.workspace(localWorkspaceID) else { return }
        if let remoteWorkspaceID = workspace.cloudVMBinding?.remoteWorkspaceID,
           !remoteWorkspaceID.isEmpty {
            return
        }
        let snapshot = catalog.snapshot
        let projections = snapshot.projections.filter { $0.workspaceID == localWorkspaceID }
        guard let target = inferredRemoteWorkspaceTarget(
            projections: projections,
            resourcesByID: catalog.resources
        ) else { return }
        if let binding = workspace.cloudVMBinding,
           binding.vmID != target.machine.cloudMachineID {
            return
        }
        bind(
            localWorkspaceID: localWorkspaceID,
            machine: target.machine,
            remoteWorkspaceID: target.remoteWorkspaceID
        )
    }

    /// The one remote cmux-tui workspace a local workspace stands for. The persisted
    /// binding wins; otherwise the projected cloud resources decide, but only when
    /// every view agrees on a single remote workspace — a local workspace composing
    /// panes from several remote workspaces (or pool terminals) has no one name to
    /// write, so nothing propagates.
    func remoteTarget(
        binding: WorkspaceCloudVMBinding?,
        projectedResources: [SurfaceResource]
    ) -> (machine: SurfaceMachineID, remoteWorkspaceID: String)? {
        if let binding, let remote = binding.remoteWorkspaceID, !remote.isEmpty {
            return (.cloud(binding.vmID), remote)
        }
        var seen = Set<CloudWorkspaceRemoteIdentity>()
        var found: (SurfaceMachineID, String)?
        for resource in projectedResources where !resource.machine.isLocal {
            for workspace in resource.remoteWorkspaces {
                seen.insert(CloudWorkspaceRemoteIdentity(
                    machine: resource.machine,
                    workspaceID: workspace.id
                ))
                found = (resource.machine, workspace.id)
            }
        }
        guard seen.count == 1, let found else { return nil }
        return (found.0, found.1)
    }

    /// The daemon-side name for a local title. Legacy projection fallback titles carry
    /// a generated "<machine>: " prefix; a bound workspace preserves the exact user text.
    func remoteName(
        fromLocalTitle title: String,
        machine: SurfaceMachineID,
        stripGeneratedPrefix: Bool = true
    ) -> String? {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(machine.rawValue): "
        if stripGeneratedPrefix, name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    /// Resolves the daemon tab represented by one local projection. An explicit
    /// tab id is authoritative. A legacy projection may infer a tab only when
    /// its workspace id agrees with the resource's sole current view. A stale
    /// workspace id must fail closed, because choosing the sole view anyway can
    /// rename a different remote placement.
    func remoteTabID(for projection: SurfaceProjection?, resource: SurfaceResource) -> String? {
        if let explicit = projection?.remoteTabID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        guard let views = resource.remoteViews, views.count == 1,
              let view = views.first,
              !view.tabID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let projectedWorkspace = projection?.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectedWorkspace.isEmpty,
           projectedWorkspace != view.workspace.id {
            return nil
        }
        return view.tabID
    }

    /// Enqueues a local workspace rename. Requests for one workspace run in order; a
    /// failed request rolls the local title back only when no newer edit replaced it.
    @MainActor
    func propagate(
        workspace: Workspace,
        localTitle: String?,
        previousCustomTitle: String?,
        catalog: SurfaceCatalog
    ) {
        guard let localTitle, !localTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A persisted binding is authoritative. Avoid scanning and sorting every
        // projection on the common bound path; the projection fallback is only for
        // legacy workspaces that predate the binding id.
        let snapshot = catalog.snapshot
        let projected = snapshot.projections.filter { $0.workspaceID == workspace.id }
        let target: (machine: SurfaceMachineID, remoteWorkspaceID: String)?
        if let bindingTarget = remoteTarget(binding: workspace.cloudVMBinding, projectedResources: []) {
            target = bindingTarget
        } else if let inferred = inferredRemoteWorkspaceTarget(
            projections: projected,
            resourcesByID: catalog.resources
        ) {
            target = inferred
        } else if projected.isEmpty {
            // A pre-catalog session may still have no projection records. Keep the
            // historical resource-only fallback for that narrow legacy case.
            target = remoteTarget(
                binding: workspace.cloudVMBinding,
                projectedResources: catalog.resourcesProjected(inWorkspace: workspace.id)
            )
        } else {
            target = nil
        }
        guard let target else { return }
        let remoteWorkspaceName = snapshot.resources(on: target.machine)
            .flatMap(\.remoteWorkspaces)
            .first(where: { $0.id == target.remoteWorkspaceID })?.name
        let stripGeneratedPrefix = workspace.cloudVMBinding?.remoteWorkspaceID == nil
            && remoteWorkspaceName.map {
                isGeneratedPrefixedTitle(
                    previousCustomTitle,
                    machine: target.machine,
                    remoteWorkspaceName: $0
                )
            } == true
        guard let name = remoteName(
            fromLocalTitle: localTitle,
            machine: target.machine,
            // Strip the legacy prefix only when the previous title proves
            // that this workspace was generated from the same remote name.
            // A user can intentionally type "machine: name" and that
            // exact text must reach the daemon unchanged.
            stripGeneratedPrefix: stripGeneratedPrefix
        ),
              catalog.provider(for: target.machine) != nil else { return }
        let expectedTitle = workspace.customTitle
        let manager = workspace.owningTabManager ?? environment.tabManager(workspace.id)
        let write = catalog.enqueueRemoteWorkspaceRename(on: target.machine, id: target.remoteWorkspaceID, name: name)
        Task { @MainActor [weak workspace, weak manager] in
            do {
                try await write.value
            } catch {
                guard let workspace,
                      workspace.customTitle == expectedTitle, workspace.effectiveCustomTitleSource == .user,
                      catalog.cloudRenameCoordinator.pendingName(for: .workspace(machine: target.machine, id: target.remoteWorkspaceID)) == nil,
                      let manager else { return }
                _ = manager.setCustomTitle(
                    tabId: workspace.id,
                    title: previousCustomTitle,
                    source: .user,
                    propagateToRemoteTmux: false,
                    propagateToCloud: false
                )
                #if DEBUG
                cmuxDebugLog("cloud.rename.workspace.failed ws=\(workspace.id) error=\(String(describing: error))")
                #endif
            }
        }
    }

    func isGeneratedPrefixedTitle(
        _ previousTitle: String?,
        machine: SurfaceMachineID,
        remoteWorkspaceName: String
    ) -> Bool {
        guard let previousTitle else { return false }
        let generated = "\(machine.rawValue): \(remoteWorkspaceName)"
        return previousTitle.trimmingCharacters(in: .whitespacesAndNewlines) == generated
    }

    /// Enqueues a local pane rename or clear to the daemon tab behind it. A
    /// failed request restores the prior local override when the user has not
    /// edited the pane again.
    @MainActor
    func propagateTerminalRename(
        workspace: Workspace,
        panelID: UUID,
        resource: SurfaceResource,
        name: String,
        previousCustomTitle: String?,
        catalog: SurfaceCatalog
    ) {
        let name = CloudRemoteRenameName(rawValue: name).wireValue
        let expectedTitle = workspace.panelCustomTitles[panelID]
        let projection = catalog.projection(forPanel: panelID)
        // A daemon name belongs to one tab placement. A persisted projection id is
        // authoritative. Legacy sessions may infer a target only when there is one
        // view, because choosing among several views would rename the wrong tab.
        let tabID = remoteTabID(for: projection, resource: resource)
        guard let tabID, !tabID.isEmpty else {
            #if DEBUG
            cmuxDebugLog("cloud.rename.terminal.ambiguous panel=\(panelID) resource=\(resource.id.rawValue)")
            #endif
            return
        }
        guard catalog.provider(for: resource.machine) != nil else { return }
        let write = catalog.enqueueRemoteTabRename(on: resource.machine, id: tabID, name: name)
        Task { @MainActor [weak workspace] in
            do {
                try await write.value
            } catch {
                guard let workspace,
                      workspace.panelCustomTitles[panelID] == expectedTitle, workspace.panelCustomTitleSources[panelID] == .user,
                      catalog.cloudRenameCoordinator.pendingName(for: .tab(machine: resource.machine, id: tabID)) == nil else { return }
                _ = workspace.setPanelCustomTitle(
                    panelId: panelID,
                    title: previousCustomTitle,
                    source: .user,
                    propagateToRemoteTmux: false,
                    propagateToCloud: false
                )
                #if DEBUG
                cmuxDebugLog("cloud.rename.terminal.failed panel=\(panelID) error=\(String(describing: error))")
                #endif
            }
        }
    }

    /// Records which machine + remote workspace a just-opened local workspace stands
    /// for, so later local renames write through without guessing from its panes.
    @MainActor
    func bind(
        localWorkspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String?,
        generatedTitle: String? = nil
    ) {
        guard let vmID = machine.cloudMachineID,
              let manager = environment.tabManager(localWorkspaceID),
              let workspace = manager.workspacesById[localWorkspaceID] else { return }
        let previousBinding = workspace.cloudVMBinding
        let sameMachine = previousBinding?.vmID == vmID
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: vmID,
            isBase: sameMachine ? (previousBinding?.isBase ?? false) : false,
            remoteWorkspaceID: remoteWorkspaceID ?? (sameMachine ? previousBinding?.remoteWorkspaceID : nil)
        )
        // Local workspace creation historically records its creation title as
        // `.user`. Mark only an exact generated title as remote, and never erase
        // a real user edit that raced the bind operation.
        if let generatedTitle,
           workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
               == generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines) {
            _ = manager.setCustomTitle(
                tabId: localWorkspaceID,
                title: generatedTitle,
                source: .remote,
                propagateToRemoteTmux: false,
                propagateToCloud: false
            )
        }
    }
}
