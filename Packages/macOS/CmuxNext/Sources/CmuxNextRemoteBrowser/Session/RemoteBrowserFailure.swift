public import CmuxNextRemoteView
import Foundation

#if DEBUG
/// Why a remote tab shows no page (cx-erey). The tab says it in its page
/// area and its title (`RemoteBrowserStrings.failure`), instead of staying
/// blank.
public nonisolated enum RemoteBrowserFailure: Error, Sendable, Hashable {
    /// The host refused the rd hello: it serves only a viewer with its
    /// per-launch secret. `hadSecret`: the tab sent one, and it was wrong.
    case refused(hadSecret: Bool)
    /// Nothing answered at the address, or it closed before the session
    /// started.
    case unreachable
    /// The connection closed after the page streamed.
    case connectionLost
    /// The host ended the session.
    case hostEnded
    /// The secret file at `path` could not be used; the tab did not connect.
    case secretFile(RemoteBrowserSecretFile.Failure, path: String)

    /// The failure an rd session end means; nil when the viewer stopped it
    /// (the tab closed). `streamed`: the session reached streaming before.
    public init?(end: RemoteSessionEnd, streamed: Bool, hadSecret: Bool) {
        switch end {
        case .stoppedByViewer: return nil
        case .consentDenied: self = .refused(hadSecret: hadSecret)
        case .connectionLost: self = streamed ? .connectionLost : .unreachable
        case .hostStoppedSharing, .disconnectedBy: self = .hostEnded
        }
    }
}
#endif
