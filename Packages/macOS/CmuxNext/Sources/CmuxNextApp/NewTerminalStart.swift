import CmuxNextTerminal

/// Where a person's new terminal starts when no folder was named
/// (NEW-TERMINAL-INHERITS-CWD, cx-zld). By default it inherits: the caller
/// passes the focused terminal's folder or nothing, and the daemon's
/// new-terminal resolver decides. Ghostty's `window-`, `tab-` or
/// `split-inherit-working-directory = false` turns that off for its kind:
/// the terminal starts in the home folder, an explicit folder still wins.
enum NewTerminalStart {
    /// The start folder of a new terminal of `kind` whose caller named none:
    /// nil while it inherits, else the home folder.
    @MainActor static func uninherited(_ kind: GhosttyWorkingDirectoryInheritance.Kind) -> String? {
        GhosttyRuntime.shared.workingDirectoryInheritance.uninheritedStart(kind)
    }
}
