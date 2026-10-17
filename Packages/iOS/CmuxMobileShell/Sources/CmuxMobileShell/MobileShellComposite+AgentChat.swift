internal import CmuxMobileRPC
public import Foundation

/// Artifact RPC access for the shell store: an event source bound to the
/// current Mac connection, consumed by the terminal/panel artifact loaders.
extension MobileShellComposite {
    /// Changes whenever the active Mac transport is replaced. The Chat UI uses
    /// this identity to restart its event and transcript streams after a
    /// reconnect without exposing the shell's broader connection state.
    public var chatConnectionGeneration: UUID {
        connectionGeneration
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
