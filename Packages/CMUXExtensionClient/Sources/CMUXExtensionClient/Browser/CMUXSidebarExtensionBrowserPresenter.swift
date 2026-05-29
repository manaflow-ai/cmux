import AppKit
import ExtensionKit
import Foundation

@available(macOS 13.0, *)
@MainActor
public enum CMUXSidebarExtensionBrowserPresenter {
    public static func present(from anchorView: NSView, title: String) {
        let browserViewController = EXAppExtensionBrowserViewController()
        browserViewController.title = title

        let browserWindow = NSWindow(contentViewController: browserViewController)
        browserWindow.title = title
        browserWindow.styleMask = [.titled, .closable, .resizable]
        browserWindow.contentMinSize = NSSize(width: 520, height: 420)
        browserWindow.setContentSize(NSSize(width: 680, height: 560))
        browserWindow.isReleasedWhenClosed = true

        if let parentWindow = anchorView.window {
            parentWindow.beginSheet(browserWindow)
        } else {
            browserWindow.center()
            browserWindow.makeKeyAndOrderFront(nil)
        }
    }
}
