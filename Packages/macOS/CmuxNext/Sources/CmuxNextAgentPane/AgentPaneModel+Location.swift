extension AgentPaneModel {
    /// This Mac's name (System Settings > General > Sharing) for the page's location row. The
    /// App sets it once it is read; every pane's next handshake carries it.
    public static var localMachineName: String?
}
