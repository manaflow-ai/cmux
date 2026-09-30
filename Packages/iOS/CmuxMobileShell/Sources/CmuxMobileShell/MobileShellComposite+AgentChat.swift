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
            supportsArtifactLane: supportsIrohArtifactLane,
            diagnosticLog: diagnosticLog
        )
    }

    /// Creates the acpmux-backed conversation source for the native GUI. It
    /// intentionally lives beside the existing transcript source so callers
    /// choose a backend explicitly instead of making the UI depend on one.
    public func makeAcpmuxChatEventSource() -> AcpmuxMobileEventSource? {
        guard connectionState == .connected,
              let client = remoteClientForAgentChat else { return nil }
        return AcpmuxMobileEventSource(client: client)
    }
}
