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

    /// `newTab`'s `focus` argument; the keyboard, menu and palette pass none
    /// and show the workspace.
    init(_ invocation: ActionInvocation) {
        shows = invocation["focus"]?.boolValue ?? true
        activatesApp = invocation["focus"]?.boolValue == true
    }
}
