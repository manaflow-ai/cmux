public import CmuxMobileHost

/// `BrowserPageHost` over the app's browser tabs (c2-browser-stream.md 9):
/// a tab must be a browser tab of this Mac and on screen, since its pixels
/// come from its window through ScreenCaptureKit.
public struct TabBrowserPages: BrowserPageHost {
    private let tabs: any MobileBrowserTabs

    public init(tabs: any MobileBrowserTabs) {
        self.tabs = tabs
    }

    public func attach(_ request: BrowserAttachRequest) async throws -> any BrowserPageAttachment {
        let tabs = tabs
        let found = await MainActor.run { () -> (tab: any MobileBrowserTab, placement: MobileBrowserPlacement?)? in
            guard let tab = tabs.tab(request.tab) else { return nil }
            return (tab, tab.placement)
        }
        guard let found else { throw BrowserPageError.tabNotFound }
        guard let placement = found.placement else {
            throw BrowserPageError.failed("the tab is not on screen on this Mac")
        }
        return await TabBrowserPageAttachment.start(tab: found.tab, placement: placement)
    }
}
