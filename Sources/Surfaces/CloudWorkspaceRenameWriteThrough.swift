import Foundation

/// Bridges local workspace titles and the canonical cmux-tui workspace name.
///
/// A cloud workspace can be projected into several local windows.  This helper resolves the
/// remote identity by stable ids, writes user edits through the provider, and replays the
/// daemon's name onto every matching local projection.  It intentionally refuses an inferred
/// target when projections disagree, because a duplicate display name is not an identity.
enum CloudWorkspaceRenameWriteThrough {
    /// Posted when a local title could not be committed remotely.  The Machines panel consumes
    /// this as an inline, localized-safe error instead of presenting a stale optimistic title.
    static let didFailNotification = Notification.Name("cmux.cloudWorkspaceRenameDidFail")

    /// The remote identity represented by a local workspace.
    struct Target: Hashable, Sendable {
        let machine: SurfaceMachineID
        let workspaceID: String
    }

    /// Associates a local workspace with the exact daemon workspace it displays.  Existing
    /// Base state is preserved, and an omitted remote id never erases a known binding.
    @MainActor
    static func bind(
        localWorkspaceID: UUID,
        machine: SurfaceMachineID,
        remoteWorkspaceID: String?
    ) {
        guard let vmID = machine.cloudMachineID,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: localWorkspaceID) else {
            return
        }
        let normalizedRemoteID = WorkspaceCloudVMBinding.normalizedRemoteWorkspaceID(remoteWorkspaceID)
        let previous = workspace.cloudVMBinding
        let preservedRemoteID = normalizedRemoteID ?? previous?.remoteWorkspaceID
        workspace.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: vmID,
            isBase: previous?.vmID == vmID ? (previous?.isBase ?? false) : false,
            remoteWorkspaceID: preservedRemoteID
        )
        if preservedRemoteID == nil {
            reconcileBinding(localWorkspaceID: localWorkspaceID)
        }
    }

    /// Fills a missing binding after a projection is restored or moved.  The inference is valid
    /// only when every identity-bearing cloud resource agrees on one machine/workspace pair.
    @MainActor
    static func reconcileBinding(localWorkspaceID: UUID, catalog suppliedCatalog: SurfaceCatalog? = nil) {
        let catalog = suppliedCatalog ?? SurfaceCatalog.shared
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: localWorkspaceID),
              workspace.cloudVMBinding?.remoteWorkspaceID == nil else {
            return
        }
        guard let target = target(for: workspace, snapshot: catalog.snapshot) else { return }
        bind(
            localWorkspaceID: localWorkspaceID,
            machine: target.machine,
            remoteWorkspaceID: target.workspaceID
        )
    }

    /// Writes a user-originated local workspace rename through to cmux-tui.  The provider owns
    /// the optimistic catalog update and revision fence; this method only restores the local
    /// title when the request fails and no newer local edit has replaced it.
    @MainActor
    static func propagate(
        workspace: Workspace,
        localTitle: String?,
        previousCustomTitle: String?
    ) {
        guard let localTitle, !localTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let catalog = SurfaceCatalog.shared
        let snapshot = catalog.snapshot
        guard isCloudCandidate(workspace: workspace, snapshot: snapshot) else { return }
        guard let target = target(for: workspace, snapshot: snapshot) else {
            reject(workspace: workspace, previousCustomTitle: previousCustomTitle, message: String(
                localized: "cloudTree.error.renameAmbiguous",
                defaultValue: "This workspace maps to more than one cloud workspace. Rename it from the Cloud machine row."
            ))
            return
        }
        guard let name = remoteName(from: localTitle, workspace: workspace, catalog: catalog) else {
            reject(workspace: workspace, previousCustomTitle: previousCustomTitle, message: String(
                localized: "cloudTree.error.renameWorkspaceEmpty",
                defaultValue: "A cloud workspace name cannot be empty."
            ))
            return
        }
        guard let provider = catalog.provider(for: target.machine),
              let manager = workspace.owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id) else {
            reject(workspace: workspace, previousCustomTitle: previousCustomTitle, message: String(
                localized: "cloudTree.error.renameUnavailable",
                defaultValue: "This cloud workspace is not connected. Refresh the machine and retry."
            ))
            return
        }
        let expectedTitle = workspace.customTitle
        Task { @MainActor [weak workspace, weak manager] in
            guard let manager else { return }
            do {
                try await provider.renameRemoteWorkspace(id: target.workspaceID, name: name)
            } catch {
                guard let workspace,
                      workspace.customTitle == expectedTitle else {
                    return
                }
                _ = manager.setCustomTitle(
                    tabId: workspace.id,
                    title: previousCustomTitle,
                    source: .user,
                    propagateToRemoteTmux: false,
                    propagateToCloud: false
                )
                NotificationCenter.default.post(
                    name: Self.didFailNotification,
                    object: nil,
                    userInfo: ["message": CloudMachineLink.errorText(error)]
                )
            }
        }
    }

    @MainActor
    private static func reject(
        workspace: Workspace,
        previousCustomTitle: String?,
        message: String
    ) {
        let manager = workspace.owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id)
        if let manager {
            _ = manager.setCustomTitle(
                tabId: workspace.id,
                title: previousCustomTitle,
                source: .user,
                propagateToRemoteTmux: false,
                propagateToCloud: false
            )
        }
        NotificationCenter.default.post(
            name: Self.didFailNotification,
            object: nil,
            userInfo: ["message": message]
        )
    }

    @MainActor
    private static func isCloudCandidate(
        workspace: Workspace,
        snapshot: SurfaceCatalogSnapshot
    ) -> Bool {
        if workspace.cloudVMBinding != nil { return true }
        let resources = Dictionary(
            snapshot.resources.map { ($0.id, $0.machine) },
            uniquingKeysWith: { first, _ in first }
        )
        return snapshot.projections.contains { projection in
            projection.workspaceID == workspace.id
                && (resources[projection.resource].map { !$0.isLocal } ?? false)
        }
    }

    /// Reconciles all local projections with the names in the catalog's latest accepted cloud
    /// graph.  A bound projection always follows its remote name; a legacy unbound projection
    /// is changed only when its current title is the old generated name, so a mixed workspace
    /// cannot have an unrelated local title silently overwritten.
    @MainActor
    static func reconcileRemoteProjections(catalog suppliedCatalog: SurfaceCatalog? = nil) {
        let catalog = suppliedCatalog ?? SurfaceCatalog.shared
        let snapshot = catalog.snapshot
        for manager in tabManagers() {
            for workspace in manager.tabs {
                guard let target = target(for: workspace, snapshot: snapshot),
                      let remoteName = remoteWorkspaceName(target, snapshot: snapshot) else {
                    continue
                }
                let current = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let bound = workspace.cloudVMBinding?.remoteWorkspaceID == target.workspaceID
                    && workspace.cloudVMBinding?.vmID == target.machine.cloudMachineID
                let generated = current.hasPrefix(target.machine.rawValue + ": ")
                guard bound || generated || current == remoteName else { continue }
                guard current != remoteName else { continue }
                _ = manager.setCustomTitle(
                    tabId: workspace.id,
                    title: remoteName,
                    source: .user,
                    propagateToRemoteTmux: false,
                    propagateToCloud: false
                )
            }
        }
    }

    /// Resolves a local workspace to one stable remote identity.  Explicit persisted bindings
    /// win; legacy projections must all agree on exactly one identity or the result is nil.
    @MainActor
    static func target(for workspace: Workspace, snapshot: SurfaceCatalogSnapshot) -> Target? {
        if let binding = workspace.cloudVMBinding,
           let remoteID = binding.remoteWorkspaceID,
           let machine = WorkspaceCloudVMBinding.normalizedVMID(binding.vmID) {
            return Target(machine: .cloud(machine), workspaceID: remoteID)
        }
        let projections = snapshot.projections.filter { $0.workspaceID == workspace.id }
        let resources = Dictionary(
            snapshot.resources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var targets = Set<Target>()
        for projection in projections {
            guard let resource = resources[projection.resource], !resource.machine.isLocal else { continue }
            let candidates = Set(resource.remoteWorkspaces.map { Target(machine: resource.machine, workspaceID: $0.id) })
            guard candidates.count <= 1 else { return nil }
            targets.formUnion(candidates)
        }
        guard targets.count == 1 else { return nil }
        return targets.first
    }

    /// Converts a local title into a daemon name.  The old generated machine prefix is removed
    /// only when the workspace is not explicitly bound; an intentional user title containing a
    /// colon therefore remains exact.
    @MainActor
    static func remoteName(
        from title: String,
        workspace: Workspace,
        catalog: SurfaceCatalog
    ) -> String? {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let target = target(for: workspace, snapshot: catalog.snapshot) else {
            return nil
        }
        if workspace.cloudVMBinding?.remoteWorkspaceID == nil {
            let prefix = target.machine.rawValue + ": "
            if value.hasPrefix(prefix),
               let currentRemoteName = remoteWorkspaceName(target, snapshot: catalog.snapshot),
               String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) == currentRemoteName {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value.isEmpty ? nil : value
    }

    @MainActor
    private static func remoteWorkspaceName(_ target: Target, snapshot: SurfaceCatalogSnapshot) -> String? {
        if let info = snapshot.machines.first(where: { $0.id == target.machine }),
           let workspace = info.remoteWorkspaces?.first(where: { $0.id == target.workspaceID }) {
            return workspace.name
        }
        var names = Set<String>()
        for resource in snapshot.resources(on: target.machine) {
            names.formUnion(resource.remoteWorkspaces.filter { $0.id == target.workspaceID }.map(\.name))
        }
        return names.count == 1 ? names.first : nil
    }

    @MainActor
    private static func tabManagers() -> [TabManager] {
        guard let app = AppDelegate.shared else { return [] }
        var result: [TabManager] = []
        var seen = Set<ObjectIdentifier>()
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  seen.insert(ObjectIdentifier(manager)).inserted else { continue }
            result.append(manager)
        }
        if let manager = app.tabManager, seen.insert(ObjectIdentifier(manager)).inserted {
            result.append(manager)
        }
        return result
    }
}
