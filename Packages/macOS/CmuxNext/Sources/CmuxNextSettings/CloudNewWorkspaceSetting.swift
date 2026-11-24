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
    public init() {}

    /// Whether a person's new workspace goes to a new Cloud machine; a missing or non-boolean value is off.
    public func inCloud(in root: JSONValue) -> Bool {
        root.value(at: Self.inCloudPath)?.boolValue ?? Self.inCloudDefault
    }

    /// Whether a Cloud chat saves a whole-machine checkpoint between turns (`cloud.turnCheckpoints`);
    /// a missing or non-boolean value is off.
    public func turnCheckpoints(in root: JSONValue) -> Bool {
        root.value(at: Self.turnCheckpointsPath)?.boolValue ?? Self.turnCheckpointsDefault
    }

    /// What a new Cloud workspace starts with; a missing or unknown value inherits.
    public func folder(in root: JSONValue) -> CloudWorkspaceFolder {
        root.value(at: Self.folderPath)?.stringValue.flatMap(CloudWorkspaceFolder.init(rawValue:)) ?? Self.folderDefault
    }
}
