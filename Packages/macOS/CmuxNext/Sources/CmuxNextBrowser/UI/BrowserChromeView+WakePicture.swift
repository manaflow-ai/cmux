public import CoreGraphics
import AppKit

extension BrowserChromeView {
    /// Keeps `picture` over the page while the page, just woken from hibernation, has not drawn
    /// its document: the pane shows the page as it slept from the first frame, not the new
    /// engine page's empty view (a WebKit page restores in the same turn its tab shows).
    ///
    /// The picture is the one the hibernated tab's placeholder showed
    /// (`HibernatedBrowserTab.wakePicture`, already decoded). It never takes a click or scroll,
    /// and it goes when the page's first load ends, its content process exits, another page
    /// takes this toolbar, ``WakePictureCover/limitAfterCommit`` after its document commits
    /// (WebKit reports no first paint), or ``WakePictureCover/limit`` after the wake. Only for
    /// pages drawn in this view: a child-window page (Chromium) draws above it.
    ///
    /// - Parameter picture: The page's last picture; nil covers nothing.
    public func holdPicture(whileWaking picture: CGImage?) {
        guard let picture, tab.presentation == .inView else { return wakePicture.end() }
        wakePicture.begin(picture, over: tab.contentView, in: contentContainer)
        wakePicture.follow(tab.state)
    }

    /// The picture over the woken page now, if any.
    var wakePictureView: NSView? { wakePicture.view }
}
