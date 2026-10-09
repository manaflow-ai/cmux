public import CmuxRemoteDesktop

/// What the host indicator shows for one live session.
public struct RemoteDesktopIndicatorSession: Hashable, Sendable {
    public var install: String
    public var target: DesktopTargetInfo
    public var mode: DesktopMode

    public init(install: String, target: DesktopTargetInfo, mode: DesktopMode) {
        self.install = install
        self.target = target
        self.mode = mode
    }
}
