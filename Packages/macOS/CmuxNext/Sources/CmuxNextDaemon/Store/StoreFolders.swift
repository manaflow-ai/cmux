/// The folders tabs report (`TabModel.cwd`): where a new chat on another machine starts and which
/// projects its New Tab page offers, read from that machine's store (never this Mac's disk).
extension WorkspaceModel {
    /// The first absolute folder a tab of this workspace reports; nil when none does.
    public var firstTabFolder: String? {
        screens.lazy.flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd).first { $0.hasPrefix("/") }
    }
}

extension DaemonStore {
    /// Every absolute folder the tabs of every workspace report, once each, in tree order.
    public var tabFolders: [String] {
        var folders: [String] = []
        var seen = Set<String>() // a set, not `folders.contains`: one pass, not one per folder per tab
        for folder in workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd)
            where folder.hasPrefix("/") && seen.insert(folder).inserted { folders.append(folder) }
        return folders
    }
}
