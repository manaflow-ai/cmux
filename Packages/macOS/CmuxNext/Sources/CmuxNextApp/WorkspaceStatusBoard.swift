import Observation

/// The status line hooks report per workspace (v1 `set_status`,
/// `set_progress`, stored by the compat layer), mirrored for the sidebar
/// row's subtitle slot. Keyed by the workspace UUID in uppercase (the old
/// app's form of the durable key); the compat store stays the owner.
@Observable
final class WorkspaceStatusBoard {
    private(set) var lines: [String: String] = [:]

    func set(_ line: String?, workspace uuid: String) {
        let key = uuid.uppercased()
        if lines[key] != line { lines[key] = line }
    }

    /// The line for a workspace id (`WorkspaceModel.id`, its key).
    func line(for workspaceID: String) -> String? {
        lines.isEmpty ? nil : lines[workspaceID.uppercased()]
    }
}
