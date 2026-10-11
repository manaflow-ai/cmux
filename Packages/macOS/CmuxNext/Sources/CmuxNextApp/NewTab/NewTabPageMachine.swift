import CmuxNextDaemon
import Foundation

/// The machine a New Tab page opens on (cx-gaq9): the folder and home it shows
/// are that machine's, from its daemon's tree, never this Mac's when the tab
/// runs on an SSH or Cloud machine.
struct NewTabPageMachine {
    /// The page's folder: the selected tab's, else the first folder another tab of its
    /// workspace reports on that machine (a remote workspace's chat tab has none).
    let cwd: String?
    /// This Mac's home for a local tab; nil on another machine, whose home the app does not
    /// know, so a typed `~/path` is never read as a file on this Mac.
    let home: String?
    /// The project choices on another machine: the folders its workspaces' tabs report there;
    /// nil for this Mac (the page lists this Mac's projects). Never this Mac's folders (cx-k21v).
    let remoteFolders: [String]?

    @MainActor init(_ services: AppServices, selected: TabModel?) {
        guard let selected else {
            (cwd, home, remoteFolders) = (nil, NSHomeDirectory(), nil)
            return
        }
        let daemon = services.machines.daemon(forTab: selected)
        guard !daemon.isLocal else {
            (cwd, home, remoteFolders) = (selected.cwd, NSHomeDirectory(), nil)
            return
        }
        let store = daemon.store
        let workspace = store.pane(containing: selected.surface).flatMap { store.workspace(containing: $0.handle) }
        let folder = workspace?.screens.flatMap(\.panes).flatMap(\.tabs).lazy.compactMap(\.cwd).first
        var folders: [String] = []
        for path in store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd)
            where path.hasPrefix("/") && !folders.contains(path) { folders.append(path) }
        (cwd, home, remoteFolders) = (selected.cwd ?? folder, nil, folders)
    }
}
