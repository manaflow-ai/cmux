import Foundation

/// One durable display view attached to a Cloud workspace.
///
/// The daemon stores these values in a frontend projection because a VNC display
/// is a machine resource rather than a cmux-tui tab. `machine`, `workspaceID`,
/// and `displayID` are the ownership identity; `clientID` and `viewID` let
/// independent clients remove only the view they created.
public struct CloudVMDisplayMembership: Hashable, Codable, Sendable {
    /// Schema stored in the daemon's frontend projection record.
    public static let projectionSchema = "cmux.cloud.workspace-displays.v1"
    /// Frontend identity authorized to author this projection.
    public static let projectionFrontendID = "cmux-macos-cloud-layout-v1"
    /// Projection generation used to reject stale frontend implementations.
    public static let projectionGeneration = "cmux-cloud-display-layout-v1"

    /// Stable window subject used to scope one machine workspace projection.
    public static func projectionWindowID(machine: SurfaceMachineID, workspaceID: String) -> String {
        "cloud-workspace:\(machine.rawValue):\(workspaceID)"
    }

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
        let expectedSessionID = (document.value(forKey: "session") as? [String: Any])?["id"] as? String
        for row in document.objects(forCollectionKey: "frontend_projections") ?? [] {
            guard row["frontend_id"] as? String == CloudVMDisplayMembership.projectionFrontendID,
                  row["generation"] as? String == CloudVMDisplayMembership.projectionGeneration else { continue }
            if let expectedSessionID, row["session_id"] as? String != expectedSessionID { continue }
            guard let projection = row["projection"] as? [String: Any],
                  projection["schema"] as? String == CloudVMDisplayMembership.projectionSchema,
                  projection["machine_id"] as? String == machine.rawValue,
                  let workspaceID = projection["workspace_id"] as? String,
                  workspaceIDs.contains(workspaceID),
                  row["window_id"] as? String == CloudVMDisplayMembership.projectionWindowID(machine: machine, workspaceID: workspaceID),
                  let memberships = projection["memberships"] as? [[String: Any]] else { continue }
            for membership in memberships {
                guard let displayID = membership["display_id"] as? String,
                      displayID.hasPrefix("display:"),
                      displayID.dropFirst("display:".count).isEmpty == false,
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

/// Names given to a machine's displays. A display is a machine resource, so its
/// name is one per display and shared by every client, sidebar row and pane
/// that shows it. Stored as a frontend projection beside the memberships so a
/// rename reaches every client through the daemon's live graph.
public enum CloudVMDisplayNames {
    public static let projectionSchema = "cmux.cloud.display-names.v1"

    public static func projectionWindowID(machine: SurfaceMachineID) -> String {
        "cloud-display-names:\(machine.rawValue)"
    }

    /// Longest stored name; longer input is truncated before writing.
    public static let maxNameLength = 80
}

extension CloudVMState {
    /// Validated display names from the accepted frontend projection, keyed by
    /// display id. Rows from another frontend, machine or session are ignored.
    public var displayNames: [String: String] {
        let expectedSessionID = (document.value(forKey: "session") as? [String: Any])?["id"] as? String
        var result: [String: String] = [:]
        for row in document.objects(forCollectionKey: "frontend_projections") ?? [] {
            guard row["frontend_id"] as? String == CloudVMDisplayMembership.projectionFrontendID,
                  row["generation"] as? String == CloudVMDisplayMembership.projectionGeneration,
                  row["window_id"] as? String == CloudVMDisplayNames.projectionWindowID(machine: machine) else { continue }
            if let expectedSessionID, row["session_id"] as? String != expectedSessionID { continue }
            guard let projection = row["projection"] as? [String: Any],
                  projection["schema"] as? String == CloudVMDisplayNames.projectionSchema,
                  projection["machine_id"] as? String == machine.rawValue,
                  let names = projection["names"] as? [String: Any] else { continue }
            for (displayID, value) in names {
                guard displayID.hasPrefix("display:"), let name = value as? String else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result[displayID] = String(trimmed.prefix(CloudVMDisplayNames.maxNameLength)) }
            }
        }
        return result
    }
}
