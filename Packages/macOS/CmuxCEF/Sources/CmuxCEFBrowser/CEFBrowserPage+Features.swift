public import CmuxBrowser

/// Native find: the panel's find bar drives Chromium's own find through the page's session.
extension CEFBrowserPage: BrowserPageNativeFinding {
    public var nativeFind: BrowserNativeFindSession { features.nativeFind }
}

/// In-pane DevTools: every DevTools entry point runs through the pane controller.
extension CEFBrowserPage: BrowserPageDevToolsHosting {
    public var devToolsState: BrowserDevToolsState { features.devTools.state }

    public func performDevTools(_ command: BrowserDevToolsCommand) {
        features.devTools.perform(command)
    }

    public func setDevToolsFocused(_ focused: Bool) {
        features.devTools.setFocused(focused)
    }
}

/// Context menus: Chromium asks the host to show its menu; the panel adds its cmux rows.
extension CEFBrowserPage: BrowserPageContextMenuCustomizing {
    public var contextMenuHost: (any BrowserContextMenuHosting)? {
        get { features.contextMenuHost }
        set { features.contextMenuHost = newValue }
    }
}
