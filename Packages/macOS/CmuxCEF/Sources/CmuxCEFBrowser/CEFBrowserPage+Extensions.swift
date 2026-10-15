public import CmuxBrowser

extension CEFBrowserPage: BrowserExtensionHostProviding {
    /// The page's extension host, when the engine was set up with extension support.
    public var extensionHost: (any BrowserExtensionHosting)? { extensionSupport }
}
