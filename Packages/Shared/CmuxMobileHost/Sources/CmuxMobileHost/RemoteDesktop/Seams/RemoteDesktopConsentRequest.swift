public import CmuxRemoteDesktop

/// What the consent panel on the Mac shows.
public struct RemoteDesktopConsentRequest: Hashable, Sendable {
    /// The paired device's install id; the app maps it to the device name.
    public var install: String
    public var target: DesktopTargetInfo
    public var mode: DesktopMode

    public init(install: String, target: DesktopTargetInfo, mode: DesktopMode) {
        self.install = install
        self.target = target
        self.mode = mode
    }
}
