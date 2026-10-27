import CmuxNextDaemon
import CmuxNextTerminal

/// Where a person's new terminal starts when no folder was named
/// (NEW-TERMINAL-INHERITS-CWD, cx-zld). By default it inherits: the caller
/// passes the focused terminal's folder or nothing, and the daemon's
/// new-terminal resolver decides. Ghostty's `window-`, `tab-` or
/// `split-inherit-working-directory = false` turns that off for its kind:
/// the terminal starts in the home folder, an explicit folder still wins.
/// Only on this Mac's daemon: the home folder is this Mac's path, so a
/// terminal of another machine (its daemon, or a remote terminal tab beside
/// it) keeps its own folder rules.
enum NewTerminalStart {
    /// The start folder of a new terminal of `kind` whose caller named none,
    /// opened on `daemon` beside `tab`: nil while it inherits, else the home folder.
    @MainActor static func uninherited(_ kind: GhosttyWorkingDirectoryInheritance.Kind, services: AppServices,
                                       daemon: DaemonService, besides tab: TabModel?) -> String? {
        guard daemon === services.daemon, tab?.kind != .remoteTerminal else { return nil }
        return GhosttyRuntime.shared.workingDirectoryInheritance.uninheritedStart(kind)
    }

    /// Whether a new terminal of `kind` inherits the focused terminal's folder (the config key).
    @MainActor static func inherits(_ kind: GhosttyWorkingDirectoryInheritance.Kind) -> Bool {
        GhosttyRuntime.shared.workingDirectoryInheritance.inherits(kind)
    }

    /// The folder a new terminal inherits from `tab`, the tab the person works in: a terminal's
    /// reported folder, an agent chat's exact folder (the daemon records none for a chat tab, and
    /// its resolver skips them). Nil for any other tab. Callers apply ``uninherited`` first.
    @MainActor static func folder(of tab: TabModel?, services: AppServices) -> String? {
        guard let tab else { return nil }
        return tab.kind == .pty ? tab.cwd : services.agentTabs.terminalFolder(of: tab.id)
    }

    /// The folder a new terminal or agent chat opened beside `tab` in `pane` inherits
    /// (NEW-WORK-INHERITS-CONTEXT, ``WorkContextTrail``): `tab`'s own when it is a terminal or a
    /// chat, else the terminal or chat the person focused last in the pane's workspace, else (for a
    /// workspace with none of its own) in the window. Nil leaves the caller's fallback (the daemon's
    /// resolver, then the home folder). Callers apply ``uninherited`` first.
    @MainActor static func inherited(besides tab: TabModel?, in pane: PaneModel?, services: AppServices) -> String? {
        services.inheritedWork(besides: tab, in: pane, kinds: [.terminal, .chat]) { folder(of: $0, services: services) }
            ?? folder(of: tab, services: services)
    }
}
