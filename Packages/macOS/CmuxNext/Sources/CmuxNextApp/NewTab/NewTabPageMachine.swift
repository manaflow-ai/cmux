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

    /// `pane`: the pane the page opens in. With no selected tab (an empty pane) its machine
    /// decides: a pane of another machine uses its workspace's folder there, never this Mac's.
    @MainActor init(_ services: AppServices, selected: TabModel?, pane: PaneController? = nil) {
        guard let daemon = selected.map(services.machines.daemon(forTab:)) ?? pane?.daemon, !daemon.isLocal else {
            // Beside an agent chat, the chat's exact folder (it has no daemon folder).
            (cwd, home, remoteFolders) = (NewTerminalStart.inherited(besides: selected, in: pane?.pane ?? selected.flatMap { services.locateTab($0.id)?.1 }, services: services) ?? selected?.cwd,
                                       NSHomeDirectory(), nil)
            return
        }
        let store = daemon.store
        let workspace = selected.flatMap { store.pane(containing: $0.surface) }.flatMap { store.workspace(containing: $0.handle) }
            ?? pane.flatMap { store.workspace(containing: $0.pane.handle) }
        (cwd, home, remoteFolders) = (selected?.cwd ?? workspace?.firstTabFolder, nil, store.tabFolders)
    }
}
