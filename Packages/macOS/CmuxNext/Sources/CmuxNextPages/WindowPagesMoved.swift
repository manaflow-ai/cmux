public import AppKit
import CmuxNextBrowserCore

extension NSView {
    /// A Chromium page's window follows its view only when told (CEFHostView.pagesNeedUpdate): tells this
    /// view's window, when it is in one. For a view that holds a page and changed place.
    @MainActor public func tellWindowItsPagesMoved() {
        guard let window else { return }
        NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
    }
}
