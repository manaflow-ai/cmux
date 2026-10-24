public import AppKit

/// A window that shows views for a test, never ordered on screen.
///
/// A ``PageWebView`` in Chromium mode makes its Chromium page (and so its renderer) only once it
/// first shows: in a window and not hidden. A test that drives the Chromium page shows the view
/// here first. Keep the stage in a stored property of the suite, so the window lives as long as
/// the test (a view holds its window weakly).
///
/// The window reports itself on screen (AppKit's `occlusionState` of a window never ordered in
/// says covered), so a page in it counts as seen; ``isOnScreen`` covers it, as a minimized,
/// ordered-out or covered window is, and posts AppKit's occlusion notice.
///
/// ```swift
/// private let stage = PageTestWindow()
/// let view = stage.show(try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting)))
/// await view.chromiumStart?.value
/// stage.isOnScreen = false // the window is covered: the page is unseen
/// ```
@MainActor
public final class PageTestWindow {
    /// A window whose occlusion the test sets.
    private final class StageWindow: NSWindow {
        var onScreen = true

        override var occlusionState: NSWindow.OcclusionState { onScreen ? .visible : [] }
    }

    private let stage: StageWindow

    /// The window; borderless, not released when closed.
    public var window: NSWindow { stage }

    /// Whether the window counts as on screen (true at first). Setting it posts
    /// `NSWindow.didChangeOcclusionStateNotification` for the window, as AppKit does.
    public var isOnScreen: Bool {
        get { stage.onScreen }
        set {
            guard newValue != stage.onScreen else { return }
            stage.onScreen = newValue
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: stage)
        }
    }

    /// Makes the window.
    ///
    /// - Parameter size: Its content size; 800 x 600 by default, the size the page tests lay out at.
    public init(size: NSSize = NSSize(width: 800, height: 600)) {
        stage = StageWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                            backing: .buffered, defer: true)
        stage.isReleasedWhenClosed = false
    }

    /// Adds `view` to the window's content, so it shows.
    ///
    /// - Parameter view: The view to show.
    /// - Returns: `view`, for a call that makes and shows it in one line.
    @discardableResult
    public func show<View: NSView>(_ view: View) -> View {
        stage.contentView?.addSubview(view)
        return view
    }
}
