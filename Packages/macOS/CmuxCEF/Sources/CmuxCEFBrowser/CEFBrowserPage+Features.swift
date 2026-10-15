public import CmuxBrowser
public import CoreGraphics

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

    public func configureDevTools(dividerThickness: CGFloat, closeShortcut: BrowserDevToolsMenuShortcut?) {
        features.devTools.configure(dividerThickness: dividerThickness, closeShortcut: closeShortcut)
    }
}

/// Context menus: Chromium asks the host to show its menu; the panel adds its cmux rows.
extension CEFBrowserPage: BrowserPageContextMenuCustomizing {
    public var contextMenuHost: (any BrowserContextMenuHosting)? {
        get { features.contextMenuHost }
        set { features.contextMenuHost = newValue }
    }
}

/// Overlay holes: the panel's overlays (find bar, permission bar, crash page) plus the DevTools
/// divider become holes in the page and DevTools windows.
extension CEFBrowserPage: BrowserPageOcclusionHosting {
    public var pageOcclusionRects: [CGRect] {
        get { features.chromeOcclusionRects }
        set { features.chromeOcclusionRects = newValue }
    }
}
