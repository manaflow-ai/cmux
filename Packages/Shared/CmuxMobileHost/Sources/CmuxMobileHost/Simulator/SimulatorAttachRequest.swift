import CmuxBrowserStream

/// What a phone asked for when it opened a simulator channel.
public struct SimulatorAttachRequest: Hashable, Sendable {
    public var udid: String
    public var install: String
    public var screen: RbScreenInfo
    public var codecs: [BrowserVideoCodec]

    public init(udid: String, install: String, screen: RbScreenInfo, codecs: [BrowserVideoCodec]) {
        self.udid = udid
        self.install = install
        self.screen = screen
        self.codecs = codecs
    }
}
