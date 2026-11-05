// Workspace hibernation's flip title and refusal (plans/cmux-next/workspace-hibernation-DESIGN.md).
// Titles live in HibernationActions.xcstrings.

/// The words the App's workspace hibernation handlers show.
public nonisolated struct WorkspaceHibernationActionStrings {
    public nonisolated init() {}
    /// Keep Workspace Awake's title while the workspace may hibernate.
    public static var keepAwake: String {
        String(localized: "action.workspace.keepAwake", defaultValue: "Keep Workspace Awake", table: "HibernationActions", bundle: .module)
    }

    /// Its title while the workspace is kept awake.
    public static var allowHibernation: String {
        String(localized: "workspaceHibernation.allowHibernation", defaultValue: "Allow Workspace to Hibernate", table: "HibernationActions", bundle: .module)
    }

    /// Hibernate Workspace on a workspace shown in a window.
    public static var shownRefusal: String {
        String(localized: "workspaceHibernation.refusal.shown", defaultValue: "A workspace on screen cannot hibernate. Switch to another workspace first.",
               table: "HibernationActions", bundle: .module)
    }
}
