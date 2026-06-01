import AppKit
import ExtensionKit
import Foundation

@available(macOS 13.0, *)
@MainActor
public enum CMUXSidebarExtensionBrowserPresenter {
    public static func makeViewController(title: String) -> NSViewController {
        let browserViewController = EXAppExtensionBrowserViewController()
        browserViewController.title = title
        return browserViewController
    }

    @available(*, unavailable, message: "Open the extension browser through the host app pane-tab flow.")
    public static func present(from anchorView: NSView, title: String) {
        _ = anchorView
        _ = title
    }
}
