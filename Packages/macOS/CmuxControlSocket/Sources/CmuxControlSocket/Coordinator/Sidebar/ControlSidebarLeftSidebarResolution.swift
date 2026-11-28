internal import Foundation

/// The outcome of applying a v1 `left_sidebar` remote command app-side
/// (parse and apply both stay in the app: `LeftSidebarRemoteRequest` is
/// shared with the socket focus-policy path).
public enum ControlSidebarLeftSidebarResolution: Sendable, Equatable {
    /// The command applied; reply `OK`.
    case ok
    /// `mode` returned whether the left sidebar is showing.
    case state(visible: Bool)
    /// A parse or apply failure; `message` is the full localized reply line.
    case failure(message: String)
}
