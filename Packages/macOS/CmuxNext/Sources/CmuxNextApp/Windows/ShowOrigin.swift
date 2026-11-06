/// Where a request to show a workspace came from (`WindowManager.show(workspaceID:in:from:)`).
enum ShowOrigin: Equatable {
    /// A person's gesture inside the window asked (its sidebar): the workspace shows there.
    case thisWindow
    /// Anything else (a notification, a link, the CLI): the window that lists the workspace shows it.
    case anywhere
}
