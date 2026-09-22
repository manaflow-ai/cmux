import Foundation

extension Workspace {
    /// URL-only entrypoints have no display provenance. Use the catalog's
    /// machine/resource open path for noVNC in a VM-bound workspace.
    func acceptsUnownedBrowserURL(_ url: URL?) -> Bool {
        url?.path != "/vnc.html" || surfaceOwnershipPolicy.rejection(for: nil) == nil
    }

    /// A saved URL is a connection target, never evidence of which VM owns it.
    /// Old noVNC records without provenance may open in local workspaces only.
    func acceptsRestoredPanel(_ snapshot: SessionPanelSnapshot, projection: SurfaceProjectionRecord?, policy: SurfaceOwnershipPolicy? = nil) -> Bool {
        let policy = policy ?? surfaceOwnershipPolicy
        if let resource = snapshot.browser?.cloudResource {
            if let projection, projection.resource != resource { return false }
            return policy.rejection(for: resource.machine) == nil
        }
        if let projection { return policy.rejection(for: projection.resource.machine) == nil }
        if snapshot.type == .browser, let raw = snapshot.browser?.urlString,
           URL(string: raw)?.path == "/vnc.html" {
            return policy.rejection(for: nil) == nil
        }
        return true
    }

    /// Validate the complete saved layout before clearing panels or adopting a
    /// binding. Startup may adopt a saved owner; an already bound workspace may
    /// never be rebound as a side effect of restoring foreign display views.
    func acceptsRestoredSession(_ snapshot: SessionWorkspaceSnapshot) -> Bool {
        let savedOwner = Self.restoredCloudVMBinding(from: snapshot.cloudVM).map { SurfaceMachineID.cloud($0.vmID) }
        if let owner = surfaceOwnershipPolicy.cloudMachine, savedOwner != owner { return false }
        let policy = SurfaceOwnershipPolicy(cloudMachine: savedOwner ?? surfaceOwnershipPolicy.cloudMachine)
        let records = snapshot.surfaceProjections ?? []
        if !records.isEmpty, policy.rejection(for: records.map(\.resource)) != nil { return false }
        let byPanel = Dictionary(records.map { ($0.panelID, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.panels.allSatisfy { acceptsRestoredPanel($0, projection: byPanel[$0.id], policy: policy) }
    }
}
