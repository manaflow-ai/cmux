/// The Cloud toggle (#26062) in cmux.json: where a person's new workspace runs, and what it starts with.
///
/// ```jsonc
/// "cloud": { "newWorkspacesInCloud": true, "newWorkspaceFolder": "inherit" }
/// ```
///
/// `newWorkspacesInCloud` (off by default): on, a person's New Workspace (Cmd-N, the sidebar's +)
/// gets its own new Cloud machine instead of a workspace on this Mac. `newWorkspaceFolder`:
/// `inherit` (default) copies the folder the person works in (its git working copy) to that machine
/// and opens the workspace there; `empty` starts in the machine's empty work folder. Both are
/// listed in Settings > Machines and in the palette's Toggle Setting.
public nonisolated struct CloudNewWorkspaceSetting: Sendable {
    public static let inCloudPath = ["cloud", "newWorkspacesInCloud"]
    public static let folderPath = ["cloud", "newWorkspaceFolder"]

    /// What a new Cloud workspace starts with.
    public enum Folder: String, CaseIterable, Sendable {
        /// The person's current folder, synced to the machine.
        case inherit
        /// The machine's empty work folder (the image's working snapshot).
        case empty
    }

    public init() {}

    /// Whether a person's new workspace goes to a new Cloud machine; a missing or non-boolean value is off.
    public func inCloud(in root: JSONValue) -> Bool {
        root.value(at: Self.inCloudPath)?.boolValue ?? false
    }

    /// What a new Cloud workspace starts with; a missing or unknown value inherits.
    public func folder(in root: JSONValue) -> Folder {
        root.value(at: Self.folderPath)?.stringValue.flatMap(Folder.init(rawValue:)) ?? .inherit
    }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.cloudWorkspaces", "Cloud Workspaces")
        return [
            SettingDescriptor(
                inCloudPath, section: .machines, group: group,
                title: SettingsText.keyed("settings.cloud.newWorkspacesInCloud", "Run New Workspaces in Cloud"),
                help: SettingsText.keyed("settings.cloud.newWorkspacesInCloud.help",
                                         "Each new workspace (Cmd-N, the sidebar's +) gets its own new Cloud machine. Agent chats you start in it run on that machine."),
                kind: .toggle, default: .bool(false),
                keywords: ["cloud", "vm", "remote", "machine", "new workspace", "cmd-n", "agent", "local", "toggle"]
            ),
            SettingDescriptor(
                folderPath, section: .machines, group: group,
                title: SettingsText.keyed("settings.cloud.newWorkspaceFolder", "New Cloud Workspaces Start In"),
                help: SettingsText.keyed("settings.cloud.newWorkspaceFolder.help",
                                         "Current Folder copies the folder you work in (its whole git working copy) to the new machine. Empty Folder starts in the machine's own empty folder."),
                kind: .choice([
                    SettingChoice(Folder.inherit.rawValue, SettingsText.keyed("settings.choice.cloudFolderInherit", "Current Folder")),
                    SettingChoice(Folder.empty.rawValue, SettingsText.keyed("settings.choice.cloudFolderEmpty", "Empty Folder")),
                ]),
                default: .string(Folder.inherit.rawValue),
                keywords: ["cloud", "vm", "folder", "sync", "copy", "inherit", "empty", "snapshot", "working directory"]
            ),
        ]
    }
}
