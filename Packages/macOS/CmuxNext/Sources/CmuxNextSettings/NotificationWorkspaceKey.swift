import CmuxNextWindowRules

/// Stable key for notification settings that belong to one machine's workspace.
/// Legacy bare workspace ids stay the local machine's keys; a remote workspace also reads one
/// saved before keys were qualified, unless a workspace on this Mac holds that id (``legacyRemoteKey``).
/// The rules are cmux-window-rules `notification_keys` (`window_notifications_workspace_key`,
/// `_workspace_ids`); the closures arrive there as id lists.
public nonisolated struct NotificationWorkspaceKey {
    public nonisolated init() {}
    /// Keep existing local settings at their original key. Bare ids never apply remotely;
    /// qualification happens on every remote read and write, so migration needs no disk rewrite.
    public static func settingsKey(machine: String, workspace: String, localMachine: String) -> String {
        ask(machine: machine, workspace: workspace, localMachine: localMachine)?.settingsKey ?? workspace
    }

    /// Converts settings keys into the workspace ids expected by a single machine's sidebar.
    /// `localHolds` says whether a workspace on this Mac has an id (``legacyRemoteKey``).
    public static func workspaceIDs(_ keys: Set<String>, machine: String, localMachine: String,
                                    localHolds: (String) -> Bool) -> Set<String> {
        guard machine != localMachine else { return keys }
        let request = IDsRequest(machine: machine, localMachine: localMachine, keys: keys.sorted(),
                                 localIds: keys.filter(localHolds).sorted())
        return Set(WindowRules().call("window_notifications_workspace_ids", request, as: IDsReply.self)?.ids ?? [])
    }

    /// Whether `keys` mute `workspace` on `machine`: its own key, or for a remote workspace the
    /// legacy bare id ``legacyRemoteKey`` names.
    public static func mutes(_ keys: Set<String>, machine: String, workspace: String, localMachine: String,
                             localHolds: (String) -> Bool) -> Bool {
        ask(machine: machine, workspace: workspace, localMachine: localMachine, keys: keys,
            localIds: localHolds(workspace) ? [workspace] : [])?.mutes ?? keys.contains(workspace)
    }

    /// The bare id that still mutes remote `workspace`: a mute saved before keys were qualified by
    /// machine, so upgrading unmutes nothing. It applies only while no workspace on this Mac has
    /// that id, so a local mute never reaches a forked machine's same-id workspace. Toggling the
    /// workspace's mute removes it.
    public static func legacyRemoteKey(_ keys: Set<String>, machine: String, workspace: String, localMachine: String,
                                       localHolds: (String) -> Bool) -> String? {
        ask(machine: machine, workspace: workspace, localMachine: localMachine, keys: keys,
            localIds: localHolds(workspace) ? [workspace] : [])?.legacyRemoteKey
    }

    /// The key `workspace`'s per-workspace rule (`notifications.sounds.workspaces`) is saved under:
    /// its own key, or for a remote workspace the legacy bare id while only that has a rule and no
    /// workspace on this Mac has the id (``legacyRemoteKey``), so a rule saved by an earlier build
    /// keeps applying and an edit changes it instead of starting a new one.
    public static func ruleKey(machine: String, workspace: String, localMachine: String, hasRule: (String) -> Bool,
                               localHolds: (String) -> Bool) -> String {
        let candidates = [workspace, qualified(machine: machine, workspace: workspace)]
        let answer = ask(machine: machine, workspace: workspace, localMachine: localMachine,
                         ruleKeys: Set(candidates.filter(hasRule)), localIds: localHolds(workspace) ? [workspace] : [])
        return answer?.ruleKey ?? settingsKey(machine: machine, workspace: workspace, localMachine: localMachine)
    }

    public static func qualified(machine: String, workspace: String) -> String {
        ask(machine: machine, workspace: workspace, localMachine: machine)?.qualified ?? workspace
    }

    private struct KeyRequest: Encodable {
        var machine: String, workspace: String, localMachine: String
        var keys: [String], ruleKeys: [String], localIds: [String]
    }

    private struct KeyReply: Decodable {
        var settingsKey: String, qualified: String, mutes: Bool, legacyRemoteKey: String?, ruleKey: String
    }

    private struct IDsRequest: Encodable {
        var machine: String, localMachine: String, keys: [String], localIds: [String]
    }

    private struct IDsReply: Decodable { var ids: [String] }

    private static func ask(machine: String, workspace: String, localMachine: String, keys: Set<String> = [],
                            ruleKeys: Set<String> = [], localIds: Set<String> = []) -> KeyReply? {
        let request = KeyRequest(machine: machine, workspace: workspace, localMachine: localMachine,
                                 keys: keys.sorted(), ruleKeys: ruleKeys.sorted(), localIds: localIds.sorted())
        return WindowRules().call("window_notifications_workspace_key", request, as: KeyReply.self)
    }
}
