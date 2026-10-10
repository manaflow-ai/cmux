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
    /// The machine's name for the user on an SSH or Cloud machine (the page labels a remote
    /// home `host ~`, never a bare `~` that reads as this Mac); nil on this Mac.
    let host: String?

    @MainActor init(_ services: AppServices, selected: TabModel?) {
        guard let selected else {
            (cwd, home, host) = (nil, NSHomeDirectory(), nil)
            return
        }
        let daemon = services.machines.daemon(forTab: selected)
        guard !daemon.isLocal else {
            (cwd, home, host) = (selected.cwd, NSHomeDirectory(), nil)
            return
        }
        let store = daemon.store
        let workspace = store.pane(containing: selected.surface).flatMap { store.workspace(containing: $0.handle) }
        let folder = workspace?.screens.flatMap(\.panes).flatMap(\.tabs).lazy.compactMap(\.cwd).first
        (cwd, home, host) = (selected.cwd ?? folder, nil, services.machines.machineName(daemon.machineID) ?? daemon.machineID)
    }
}
