import AppKit
import SwiftUI

/// A cmux-owned auxiliary window that hosts SwiftUI content in a plain AppKit
/// `NSWindow`.
///
/// Unlike a SwiftUI `Window` / `WindowGroup` scene (which keeps the backing
/// window alive on close, ordered out, so a third-party switcher like AltTab can
/// resurrect a "closed" window, issue #5321), cmux owns the full lifecycle here:
/// opening creates the window, closing destroys it. When the window closes,
/// ``windowWillClose(_:)`` tells the owner to drop its reference; with no strong
/// references left the controller and window deallocate, the window leaves
/// `NSApp.windows`, and `AXUIElementDestroyed` fires so switchers drop it.
///
/// The hosted SwiftUI view (and its animations) render exactly as in a scene,
/// hosting doesn't change view-internal behavior. `sceneBridgingOptions` bridges
/// the SwiftUI scene chrome (the `NavigationSplitView` sidebar toggle + title)
/// into the window's unified toolbar so the window also *looks* like the native
/// SwiftUI scene.
@MainActor
final class CmuxHostedWindowController: NSWindowController, NSWindowDelegate {
    private let onWindowWillClose: @MainActor () -> Void

    init<Content: View>(
        identifier: String,
        title: String,
        contentSize: NSSize,
        minSize: NSSize,
        rootView: Content,
        onWindowWillClose: @escaping @MainActor () -> Void
    ) {
        self.onWindowWillClose = onWindowWillClose
        let hostingController = NSHostingController(rootView: rootView)
        // Bridge SwiftUI scene chrome (NavigationSplitView sidebar toggle + title)
        // into this AppKit window so it matches the native SwiftUI-scene Settings
        // look (macOS 13+).
        hostingController.sceneBridgingOptions = [.all]
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isRestorable = false
        // Controller-owned destruction: released when the last strong reference
        // (this controller, held by the presenter) drops on close, not via
        // `isReleasedWhenClosed` (which a SwiftUI scene self-destructs on).
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        // `sceneBridgingOptions` populates the window's toolbar with the hosted
        // view's toolbar content (the NavigationSplitView sidebar toggle) but
        // doesn't create the toolbar, so give the window one.
        let toolbar = NSToolbar()
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isExcludedFromWindowsMenu = true
        window.contentMinSize = minSize
        window.minSize = minSize
        window.setContentSize(contentSize)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        // `sceneBridgingOptions` makes the NSHostingController reference its
        // window (to drive the bridged toolbar), and the window references the
        // hosting controller as its content, a retain cycle that keeps the
        // window in the window list after close (AltTab could resurrect it,
        // issue #5321). Break it on close so the window deallocates and leaves
        // the window list.
        window?.toolbar = nil
        window?.contentViewController = nil
        onWindowWillClose()
    }
}
