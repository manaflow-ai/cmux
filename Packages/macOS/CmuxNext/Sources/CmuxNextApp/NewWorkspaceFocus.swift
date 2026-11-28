import CmuxNextActions

/// How a workspace that `newTab` creates takes focus.
struct NewWorkspaceFocus: Equatable {
    /// Selected in the active window. When false, the most recent window
    /// lists it without showing it (the CLI's default).
    var shows: Bool
    /// Its window becomes key and the app activates.
    var activatesApp: Bool

    init(shows: Bool, activatesApp: Bool) {
        self.shows = shows
        self.activatesApp = activatesApp
    }

    /// `newTab`'s `focus` and `activate` arguments. The keyboard, menu and
    /// palette pass neither and show the workspace in the key window. Only
    /// `activate: true` with focus takes the Mac's focus: `cmux open <dir>`
    /// sends it when a person runs it (`defaultFocusForUserOpen`); callers
    /// that pass `focus: true` regardless of who runs them (the local tmux
    /// attach) only select the workspace.
    init(_ invocation: ActionInvocation) {
        shows = invocation["focus"]?.boolValue ?? true
        activatesApp = shows && invocation["activate"]?.boolValue == true
    }
}
