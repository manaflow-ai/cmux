extension AgentPaneModel {
    /// The read of this Mac's name (System Settings > General > Sharing) for the page's location
    /// row. The App starts it at launch; a handshake that arrives first waits for it, so a restored
    /// pane never shows "This Mac".
    public static var localMachineName: Task<String, Never>?
    /// What ``localMachineName`` answered, once it has: a New Tab page's context carries it
    /// (`AgentPaneNewTab.host`), so the page's first frame names this Mac with no wait.
    public private(set) static var localMachineDisplayName: String?

    /// Keeps the name ``localMachineName`` answered (``localMachineDisplayName``) and returns it.
    public static func rememberLocalMachineName(_ name: String) -> String {
        localMachineDisplayName = name
        return name
    }
}
