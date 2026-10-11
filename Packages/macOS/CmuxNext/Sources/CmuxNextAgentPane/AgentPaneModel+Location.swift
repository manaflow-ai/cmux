extension AgentPaneModel {
    /// The read of this Mac's name (System Settings > General > Sharing) for the page's location
    /// row. The App starts it at launch; a handshake that arrives first waits for it, so a restored
    /// pane never shows "This Mac".
    public static var localMachineName: Task<String, Never>?
}
