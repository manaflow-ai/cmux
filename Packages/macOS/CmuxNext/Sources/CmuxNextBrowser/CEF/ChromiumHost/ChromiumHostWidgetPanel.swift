import AppKit

/// The borderless cmux panel an anchored hosted widget (``ChromiumHostWidgetHost``) shows
/// in. Page popups sit at the pop-up menu level, as Chrome's `PopupWindowMac`
/// (content/app_shim_remote_cocoa/popup_window_mac.mm) puts them; neither kind ever
/// becomes the main window, and only an extension popup becomes key.
final class ChromiumHostWidgetPanel: NSPanel {
    private let takesKey: Bool
    /// The panel stopped being key (a click elsewhere, another app): an extension popup closes,
    /// as Chrome's does (`ExtensionPopup::OnWidgetActivationChanged`,
    /// chrome/browser/ui/views/extensions/extension_popup.cc).
    var onResignKey: (() -> Void)?

    init(frame: CGRect, takesKey: Bool) {
        self.takesKey = takesKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = !takesKey
        level = takesKey ? .floating : .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        setAccessibilityIdentifier("browser.chromiumHost.widget")
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// The delegate of an undocked DevTools window the widget host shows: a move changes where its
/// page is without a frame change of the page's view, so the move asks the window's pages to
/// re-place, as a cmux window's layout owner (`WindowOverlayLayer`) does. One delegate per
/// window, as Chromium observes its NSWindows (`ViewsNSWindowDelegate`,
/// components/remote_cocoa/app_shim/views_nswindow_delegate.mm).
final class ChromiumHostWidgetWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.updateBrowserPageGeometry()
    }
}
