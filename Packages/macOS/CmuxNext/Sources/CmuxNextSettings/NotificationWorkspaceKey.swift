import Foundation

/// Stable key for notification settings that belong to one machine's workspace.
/// Legacy bare workspace ids remain readable for the local machine only.
public nonisolated enum NotificationWorkspaceKey {
    private init() {}

    /// Keep existing local settings at their original key. Bare ids never apply remotely;
    /// qualification happens on every remote read and write, so migration needs no disk rewrite.
    public static func settingsKey(machine: String, workspace: String, localMachine: String) -> String {
        machine == localMachine ? workspace : qualified(machine: machine, workspace: workspace)
    }

    /// Converts settings keys into the workspace ids expected by a single machine's sidebar.
    public static func workspaceIDs(_ keys: Set<String>, machine: String, localMachine: String) -> Set<String> {
        guard machine != localMachine else { return keys }
        let prefix = "machine:\(Data(machine.utf8).base64EncodedString()):workspace:"
        return Set(keys.compactMap { key in
            guard key.hasPrefix(prefix), let bytes = Data(base64Encoded: String(key.dropFirst(prefix.count))) else { return nil }
            return String(data: bytes, encoding: .utf8)
        })
    }

    public static func qualified(machine: String, workspace: String) -> String {
        let machinePart = Data(machine.utf8).base64EncodedString()
        let workspacePart = Data(workspace.utf8).base64EncodedString()
        return "machine:\(machinePart):workspace:\(workspacePart)"
    }
}
