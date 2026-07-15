/// Whether a hub pane contains the Mac's focused surface.
public enum WorkspaceHubFocusState: Equatable, Sendable {
    /// The pane is not focused on the Mac.
    case unfocused
    /// The pane contains the Mac's focused surface.
    case focused

    /// Maps a pane identifier and the authoritative active pane identifier to focus state.
    /// - Parameters:
    ///   - paneID: The pane being projected.
    ///   - activePaneID: The Mac's active pane, when known.
    public init(paneID: String, activePaneID: String?) {
        self = paneID == activePaneID ? .focused : .unfocused
    }

    /// Maps a flat-terminal fallback focus flag to focus state.
    /// - Parameter isFocused: Whether the legacy terminal is focused.
    public init(isFocused: Bool) {
        self = isFocused ? .focused : .unfocused
    }
}
