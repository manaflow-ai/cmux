/// `window.titlebar` in cmux.json.
public nonisolated enum TitlebarStyle: String, Sendable, CaseIterable, Codable {
    /// No titlebar strip (the default, user nxdog9): content reaches the
    /// window's top edge, the traffic lights sit in the top row, and every
    /// empty area of that row moves the window.
    case minimal
    /// A titlebar strip with the workspace name above the content.
    case standard
}
