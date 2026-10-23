public import AppKit

/// A window that shows views for a test, never ordered on screen.
///
/// A ``PageWebView`` in Chromium mode makes its Chromium page (and so its renderer) only once it
/// first shows: in a window and not hidden. A test that drives the Chromium page shows the view
/// here first. Keep the stage in a stored property of the suite, so the window lives as long as
/// the test (a view holds its window weakly).
///
/// ```swift
/// private let stage = PageTestWindow()
/// let view = stage.show(try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting)))
/// await view.chromiumStart?.value
/// ```
@MainActor
public final class PageTestWindow {
    /// The window; borderless, not released when closed.
    public let window: NSWindow

    /// Makes the window.
    ///
    /// - Parameter size: Its content size; 800 x 600 by default, the size the page tests lay out at.
    public init(size: NSSize = NSSize(width: 800, height: 600)) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
    }

    /// Adds `view` to the window's content, so it shows.
    ///
    /// - Parameter view: The view to show.
    /// - Returns: `view`, for a call that makes and shows it in one line.
    @discardableResult
    public func show<View: NSView>(_ view: View) -> View {
        window.contentView?.addSubview(view)
        return view
    }
}
