import CmuxBrowserStream

/// What a phone asked for when it opened a browser channel.
public struct BrowserAttachRequest: Hashable, Sendable {
    /// The browser tab (`tab_…`) in this host's workspace tree.
    public var tab: String
    /// The admitted device.
    public var install: String
    public var screen: RbScreenInfo
    public var codecs: [BrowserVideoCodec]

    public init(tab: String, install: String, screen: RbScreenInfo, codecs: [BrowserVideoCodec]) {
        self.tab = tab
        self.install = install
        self.screen = screen
        self.codecs = codecs
    }
}
