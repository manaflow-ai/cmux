import Foundation

extension TerminalController {
    /// Uses the existing vm.tree worker route. Only the synchronous organization
    /// mutation hops to MainActor; it never changes selection or calls a provider.
    nonisolated func socketWorkerCloudSidebarResponse(id: Any?, params: [String: Any]) -> String {
        let verb = Self.surfaceString(params["action"]) ?? "list"
        let nodeID = Self.surfaceString(params["node_id"])
        let targetID = Self.surfaceString(params["target_id"])
        return v2VmCall(id: id) {
            let rows = try await MainActor.run {
                let catalog = SurfaceCatalog.shared
                let nodes = catalog.sidebarNodes(unread: CloudNotificationSyncHub.shared.unreadTerminalIDs)
                if verb != "list" {
                    let action: CloudSidebarOrganizationAction
                    switch verb {
                    case "pin": action = .pin
                    case "unpin": action = .unpin
                    case "up": action = .up
                    case "down": action = .down
                    case "before": action = .before(targetID ?? "")
                    case "after": action = .after(targetID ?? "")
                    default: throw SurfaceCatalogError.destinationNotFound(Self.cloudSidebarInvalidAction)
                    }
                    guard let nodeID, CloudSidebarOrganizationTree(nodes: nodes).parent(of: nodeID) != nil else {
                        throw SurfaceCatalogError.destinationNotFound(Self.cloudSidebarInvalidAction)
                    }
                    guard catalog.organizeSidebar(action, nodeID: nodeID) else {
                        throw SurfaceCatalogError.destinationNotFound(Self.cloudSidebarInvalidAction)
                    }
                }
                let arranged = CloudSidebarOrganizationTree(nodes: nodes).arrange(using: catalog.sidebarOrganization.state)
                return arranged.map { CloudSidebarRowSnapshot(node: $0) }
            }
            return ["rows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))]
        }
    }

    private nonisolated static var cloudSidebarInvalidAction: String {
        String(localized: "cloudTree.organization.invalidAction", defaultValue: "Cannot move this item. Choose a current item in the same group and pin section.")
    }

}
