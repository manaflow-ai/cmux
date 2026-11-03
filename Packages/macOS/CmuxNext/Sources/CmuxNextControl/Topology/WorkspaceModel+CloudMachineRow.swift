package import CmuxNextDaemon
package import CmuxNextSettings

package extension WorkspaceModel {
    /// This workspace in its Cloud machine's row of `cloud.machines`: its durable id (`workspace_id`
    /// in `cloud new-workspace`'s answer), its name and its `ws_…` id on registry daemons;
    /// `cmux workspace list` and MCP `workspace_list` list them.
    var cloudMachineWorkspaceRow: CmuxNextSettings.JSONValue {
        .object(["id": .string(id), "name": .string(displayName),
                 "resource_id": resourceID.map { .string($0.rawValue) } ?? .null])
    }
}
