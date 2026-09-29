/// v1/v2 read methods that a server may rate-limit per connection. A
/// `rate_limited` reply to one of these is safe for the client to retry
/// after the server's delay; for any other method it is final.
public enum SocketPollingMethods {
    public static let names: Set<String> = [
        "system.top",
        "system.memory",
        "system.tree",
        "system.identify",
        "window.list",
        "window.current",
        "window.displays",
        "workspace.list",
        "workspace.current",
        "surface.list",
        "surface.current",
        "surface.read_text",
        "surface.read_selection",
        "pane.list",
        "pane.surfaces",
        "list_windows",
        "current_window",
        "list_workspaces",
        "current_workspace",
        "list_surfaces",
        "read_screen",
    ]
}
