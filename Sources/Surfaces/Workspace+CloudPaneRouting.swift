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
    func inferredRemoteWorkspaceTarget(
        projections: [SurfaceProjection],
        resources: [SurfaceResource],
        resourcesByID: [SurfaceResourceID: SurfaceResource]? = nil
    ) -> (machine: SurfaceMachineID, remoteWorkspaceID: String)? {
        guard !projections.isEmpty else { return nil }
        let resourceIndex = resourcesByID ?? Dictionary(
            resources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var targets = Set<CloudWorkspaceRemoteIdentity>()
        for projection in projections {
            guard !projection.resource.machine.isLocal,
                  let resource = resourceIndex[projection.resource] else { return nil }
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
            resources: snapshot.resources
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
        updateCloudDirectories(localWorkspaceID: localWorkspaceID, catalog: catalog)
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
