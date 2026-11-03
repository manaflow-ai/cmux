import CmuxNextDaemon

/// One change to a workspace's description and manual task status, as
/// `workspace.update` takes it: `.unchanged` leaves a field, `.clear` clears
/// the description or makes the status automatic again.
struct WorkspaceNotesUpdate: Equatable {
    var description: FieldUpdate<String> = .unchanged
    var taskStatus: FieldUpdate<WorkspaceTaskStatus> = .unchanged

    init(description: FieldUpdate<String> = .unchanged, taskStatus: FieldUpdate<WorkspaceTaskStatus> = .unchanged) {
        self.description = description
        self.taskStatus = taskStatus
    }

    /// The values of Set Workspace Status (`CatalogArgument.statusChoice`): `auto`, then the lanes.
    static let statusChoices = ["auto"] + WorkspaceTaskStatus.allCases.map(\.rawValue)

    /// Set Workspace Status' `status` argument: `auto` clears the pinned lane, a lane pins it;
    /// nil for any other text.
    init?(statusChoice: String) {
        if statusChoice == "auto" {
            self.init(taskStatus: .clear)
        } else if let lane = WorkspaceTaskStatus(rawValue: statusChoice) {
            self.init(taskStatus: .set(lane))
        } else {
            return nil
        }
    }

    /// Cycle Workspace Status: the lane after `current`, and To Do for a workspace on automatic.
    static func cycled(_ current: WorkspaceTaskStatus?) -> WorkspaceTaskStatus {
        current?.next ?? .todo
    }

    /// The daemon capabilities the fields it changes need.
    var capabilities: [String] {
        var needed: [String] = []
        if description != .unchanged { needed.append(DaemonCapability.workspaceDescription.rawValue) }
        if taskStatus != .unchanged { needed.append(DaemonCapability.workspaceStatus.rawValue) }
        return needed
    }
}
