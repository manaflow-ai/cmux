internal import CmuxMobileRPC

/// Artifact RPC access for the shell store: an event source bound to the
/// current Mac connection, consumed by the terminal/panel artifact loaders.
extension MobileShellComposite {
    /// Cache namespace for artifact bytes fetched through the current Mac
    /// connection. A reconnect may expose the same path with different bytes,
    /// so callers must include this generation in loader cache keys.
    public var artifactSourceIdentity: String {
        connectionGeneration.uuidString
    }

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
}
