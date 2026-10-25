public import AppKit

/// A fullscreen page its window gives the whole screen, as Chrome does for a page's fullscreen in
/// a window with no other content beside it. The window owns it while the page has the screen.
@MainActor
public final class BrowserPagePresentation {
    public private(set) weak var chrome: BrowserChromeView?
    public private(set) weak var tab: (any BrowserTab)?
    /// The pane that shows the page, in the host's own type.
    public private(set) weak var pane: AnyObject?
    /// The window entered macOS full screen for the page, so it leaves it after.
    public let entersWindowFullScreen: Bool

    public init(chrome: BrowserChromeView, tab: any BrowserTab, pane: AnyObject, entersWindowFullScreen: Bool) {
        self.chrome = chrome
        self.tab = tab
        self.pane = pane
        self.entersWindowFullScreen = entersWindowFullScreen
    }
}
