internal import CmuxMobileRPC

/// Artifact RPC access for the shell store: an event source bound to the
/// current Mac connection, consumed by the terminal/panel artifact loaders.
extension MobileShellComposite {
    /// An artifact event source over the current connection, or `nil` when not
    /// connected.
    public func makeChatEventSource() -> MobileChatEventSource? {
        guard connectionState == .connected,
              let client = remoteClientForAgentChat else { return nil }
        return MobileChatEventSource(
            client: client,
            supportsArtifacts: supportsChatArtifacts,
            supportsArtifactGallery: supportsChatArtifactGallery,
            supportsArtifactFolders: supportsChatArtifactFolders,
            supportsTerminalArtifactList: supportsTerminalArtifactList,
            supportsPanelArtifacts: supportsPanelArtifacts,
            diagnosticLog: diagnosticLog
        )
    }
}
