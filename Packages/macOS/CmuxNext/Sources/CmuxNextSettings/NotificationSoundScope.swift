/// Where a notification comes from, for its sound: each part names a level whose
/// ``NotificationSoundRule`` may apply. Nil or empty parts skip their level.
public nonisolated struct NotificationSoundScope: Hashable, Sendable {
    /// The agent kind of the notifying tab (`claude`, `codex`, `opencode`), lowercased.
    public var agent: String?
    /// The workspace id (`WorkspaceModel.id`, the key `notifications.mutedWorkspaces` uses).
    public var workspace: String?
    /// The workspace's groups, innermost first. A group's rule is found by its id, else its name,
    /// so a hand-written cmux.json can say `"groups": {"Agents & routing": "Submarine"}`.
    public var groups: [Group] = []

    /// One group the workspace sits in.
    public struct Group: Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public init(agent: String? = nil, workspace: String? = nil, groups: [Group] = []) {
        self.agent = agent
        self.workspace = workspace
        self.groups = groups
    }
}
