internal import Foundation

/// The outcome of applying a v1 `right_sidebar` remote command app-side
/// (parse and apply both stay in the app: `RightSidebarRemoteRequest` is
/// shared with the socket focus-policy path).
public enum ControlSidebarRightSidebarResolution: Sendable, Equatable {
    /// The command applied; reply `OK`.
    case ok
    /// A `get`-style command returned sidebar state to encode.
    case state(visible: Bool, modeRawValue: String)
    /// A parse or apply failure; `message` is the full legacy reply line
    /// (localized app-side where the original was localized).
    case failure(message: String)
}
