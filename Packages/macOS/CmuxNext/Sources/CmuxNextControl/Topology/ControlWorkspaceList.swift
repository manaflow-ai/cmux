import CmuxNextDaemon

/// One store's workspace list as the last publish mapped it, kept by
/// ``ControlWorkspaceInfoCache`` so the next publish patches only the
/// workspaces that changed or carry app facts.
///
/// `infos[i]` is the published value of `models[i]`. A class: each publish
/// patches its arrays in place.
@MainActor
final class ControlWorkspaceList {
    var models: [WorkspaceModel] = []
    var infos: [ControlWorkspaceInfo] = []
    /// Position of each model in `models`.
    var index: [ObjectIdentifier: Int] = [:]
    /// The workspace owning each pane id, from the cached values.
    var paneOwners: [String: ObjectIdentifier] = [:]
    /// Workspaces with store page tabs: their titles are app facts, so every
    /// publish applies them.
    var pageTabWorkspaces: Set<ObjectIdentifier> = []
    /// Workspaces whose `infos` value carries app facts from the last publish.
    var applied: Set<ObjectIdentifier> = []
    /// Tabs of `infos` (app facts never add or drop a pane's tabs).
    var tabCount = 0
    /// The generation of the tracking that read the list; nil once it fired.
    var generation: UInt64?

    /// Whether the list holds the workspace `key` names.
    func contains(_ key: ObjectIdentifier) -> Bool { index[key] != nil }
}
