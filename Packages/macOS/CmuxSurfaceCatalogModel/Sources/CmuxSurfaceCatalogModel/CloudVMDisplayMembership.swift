import Foundation

/// One durable display view attached to a Cloud workspace.
///
/// The daemon stores these values in a frontend projection because a VNC display
/// is a machine resource rather than a cmux-tui tab. `machine`, `workspaceID`,
/// and `displayID` are the ownership identity; `clientID` and `viewID` let
/// independent clients remove only the view they created.
public struct CloudVMDisplayMembership: Hashable, Codable, Sendable {
    public let machine: SurfaceMachineID
    public let workspaceID: String
    public let displayID: String
    public let clientID: String
    public let viewID: String

    public init(
        machine: SurfaceMachineID,
        workspaceID: String,
        displayID: String,
        clientID: String,
        viewID: String
    ) {
        self.machine = machine
        self.workspaceID = workspaceID
        self.displayID = displayID
        self.clientID = clientID
        self.viewID = viewID
    }
}

extension CloudVMState {
    /// Reads only validated display memberships from the accepted frontend
    /// projection rows. Unknown machines, workspaces, displays, and malformed
    /// view tokens are ignored so stale or foreign provenance cannot enter the
    /// catalog projection.
    public var displayMemberships: [CloudVMDisplayMembership] {
        let workspaceIDs = Set(workspaces.map(\.id))
        var result = Set<CloudVMDisplayMembership>()
        for row in document.objects(forCollectionKey: "frontend_projections") ?? [] {
            guard let projection = row["projection"] as? [String: Any],
                  projection["schema"] as? String == "cmux.cloud.workspace-displays.v1",
                  projection["machine_id"] as? String == machine.rawValue,
                  let workspaceID = projection["workspace_id"] as? String,
                  workspaceIDs.contains(workspaceID),
                  let memberships = projection["memberships"] as? [[String: Any]] else { continue }
            for membership in memberships {
                guard let displayID = membership["display_id"] as? String,
                      displayID.hasPrefix("display:"),
                      let clientID = membership["client_id"] as? String,
                      !clientID.isEmpty,
                      let viewID = membership["view_id"] as? String,
                      !viewID.isEmpty else { continue }
                result.insert(CloudVMDisplayMembership(
                    machine: machine,
                    workspaceID: workspaceID,
                    displayID: displayID,
                    clientID: clientID,
                    viewID: viewID
                ))
            }
        }
        return result.sorted {
            ($0.workspaceID, $0.displayID, $0.clientID, $0.viewID)
                < ($1.workspaceID, $1.displayID, $1.clientID, $1.viewID)
        }
    }
}
