import CmuxAgentChatUI
import CmuxMobileShellModel

extension MobileMacConnectionStatus {
    /// The artifact viewer's connection hint, so transport-failure copy says
    /// which side is down instead of always pointing the user at the Mac.
    var artifactConnectionHint: ChatArtifactConnectionHint {
        switch self {
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .unavailable: .disconnected
        }
    }
}
