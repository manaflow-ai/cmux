public import CmuxRemoteDesktop

/// What a session asks `RemoteDesktopSources.open` for.
public struct RemoteDesktopOpenRequest: Hashable, Sendable {
    public var target: DesktopTarget
    /// The phone's install (for logs and the indicator), never a credential.
    public var install: String
    /// The first region to capture, in target pixels.
    public var region: DesktopRect

    public init(target: DesktopTarget, install: String, region: DesktopRect) {
        self.target = target
        self.install = install
        self.region = region
    }
}
