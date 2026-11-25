import Foundation

/// Stable key for notification settings that belong to one machine's workspace.
/// Legacy bare workspace ids stay the local machine's keys; a remote workspace also reads one
/// saved before keys were qualified, unless a workspace on this Mac holds that id (``legacyRemoteKey``).
public nonisolated struct NotificationWorkspaceKey {
    public nonisolated init() {}
    /// Keep existing local settings at their original key. Bare ids never apply remotely;
    /// qualification happens on every remote read and write, so migration needs no disk rewrite.
    public static func settingsKey(machine: String, workspace: String, localMachine: String) -> String {
        machine == localMachine ? workspace : qualified(machine: machine, workspace: workspace)
    }

    /// Converts settings keys into the workspace ids expected by a single machine's sidebar.
    /// `localHolds` says whether a workspace on this Mac has an id (``legacyRemoteKey``).
    public static func workspaceIDs(_ keys: Set<String>, machine: String, localMachine: String,
                                    localHolds: (String) -> Bool) -> Set<String> {
        guard machine != localMachine else { return keys }
        let prefix = "machine:\(Data(machine.utf8).base64EncodedString()):workspace:"
        return Set(keys.compactMap { key in
            guard key.hasPrefix(prefix) else { return key.hasPrefix(qualifiedPrefix) || localHolds(key) ? nil : key }
            guard let bytes = Data(base64Encoded: String(key.dropFirst(prefix.count))) else { return nil }
            return String(data: bytes, encoding: .utf8)
        })
    }

    /// Whether `keys` mute `workspace` on `machine`: its own key, or for a remote workspace the
    /// legacy bare id ``legacyRemoteKey`` names.
    public static func mutes(_ keys: Set<String>, machine: String, workspace: String, localMachine: String,
                             localHolds: (String) -> Bool) -> Bool {
        keys.contains(settingsKey(machine: machine, workspace: workspace, localMachine: localMachine))
            || legacyRemoteKey(keys, machine: machine, workspace: workspace, localMachine: localMachine, localHolds: localHolds) != nil
    }

    /// The bare id that still mutes remote `workspace`: a mute saved before keys were qualified by
    /// machine, so upgrading unmutes nothing. It applies only while no workspace on this Mac has
    /// that id, so a local mute never reaches a forked machine's same-id workspace. Toggling the
    /// workspace's mute removes it.
    public static func legacyRemoteKey(_ keys: Set<String>, machine: String, workspace: String, localMachine: String,
                                       localHolds: (String) -> Bool) -> String? {
        machine != localMachine && keys.contains(workspace) && !localHolds(workspace) ? workspace : nil
    }

    /// The key `workspace`'s per-workspace rule (`notifications.sounds.workspaces`) is saved under:
    /// its own key, or for a remote workspace the legacy bare id while only that has a rule and no
    /// workspace on this Mac has the id (``legacyRemoteKey``), so a rule saved by an earlier build
    /// keeps applying and an edit changes it instead of starting a new one.
    public static func ruleKey(machine: String, workspace: String, localMachine: String, hasRule: (String) -> Bool,
                               localHolds: (String) -> Bool) -> String {
        let key = settingsKey(machine: machine, workspace: workspace, localMachine: localMachine)
        guard !hasRule(key), machine != localMachine, hasRule(workspace), !localHolds(workspace) else { return key }
        return workspace
    }

    private static let qualifiedPrefix = "machine:"

    public static func qualified(machine: String, workspace: String) -> String {
        let machinePart = Data(machine.utf8).base64EncodedString()
        let workspacePart = Data(workspace.utf8).base64EncodedString()
        return "machine:\(machinePart):workspace:\(workspacePart)"
    }
}
