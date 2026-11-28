public import AppKit

/// Where every cmux-next window opens, so no window lands on a display the
/// user did not open it from.
///
/// Auxiliary windows (Site settings, Certificate Viewer, On-device site
/// data, debug windows) open centered over their parent shell window, on
/// its screen, clamped to that screen's visible frame. In an agent
/// screenshot launch (`CMUX_NEXT_TEST_WINDOW_SCREEN` with
/// `CMUX_NEXT_NO_ACTIVATE=1`) every window opens on the test screen instead
/// and never becomes key. The App sets ``testScreen`` and ``noActivate``
/// once at launch; the shell windows use ``screenIndex(test:parent:count:)``
/// too, so both follow one rule.
@MainActor
public struct WindowPlacement {
    public init() {}
    /// `CMUX_NEXT_TEST_WINDOW_SCREEN`: an `NSScreen.screens` index (0 is the
    /// menu-bar screen) or the last screen.
    public enum TestScreen: Sendable, Equatable {
        case index(Int)
        case last
    }

    /// Set by the App at launch; nil outside agent screenshot launches.
    public static var testScreen: TestScreen?
    /// `CMUX_NEXT_NO_ACTIVATE=1`: windows never take key or activate the app.
    public static var noActivate = false
    /// Offset between windows that would otherwise open on the same spot.
    public nonisolated static let cascadeStep: CGFloat = 24

    // MARK: Pure rules

    /// The screen index a window belongs on: the test screen when set (an
    /// index past the end means the last screen), else its parent's screen.
    public nonisolated static func screenIndex(test: TestScreen?, parent: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch test {
        case .last: return count - 1
        case .index(let index): return min(max(index, 0), count - 1)
        case nil: return parent.map { min(max($0, 0), count - 1) }
        }
    }

    /// AppKit frame for a window of `size` on the screen whose visible frame
    /// is `visible`: centered over `parentFrame` when the parent is on that
    /// screen, else centered on the screen; moved by `cascade` steps; always
    /// inside `visible`.
    public nonisolated static func frame(size: CGSize, parentFrame: CGRect?, visible: CGRect, cascade: Int = 0) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let anchor = parentFrame.flatMap { visible.intersects($0) ? $0 : nil } ?? visible
        let step = cascadeStep * CGFloat(max(cascade, 0))
        var x = anchor.midX - width / 2 + step
        var y = anchor.midY - height / 2 - step
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// `frame` moved (and shrunk if needed) inside `visible`, keeping its
    /// position where it already fits.
    public nonisolated static func contain(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: AppKit

    /// `frame` kept on the test screen in an agent screenshot launch
    /// (unchanged otherwise). Shell windows apply it to every frame they
    /// are given, so no creation or move path (tear-off, new window,
    /// move-window, restore) can put one on the user's display.
    public static func containedOnTestScreen(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard let test = testScreen, let index = screenIndex(test: test, parent: nil, count: screens.count) else { return frame }
        return contain(frame, in: screens[index].visibleFrame)
    }

    /// The shell window an auxiliary window belongs to when the caller has
    /// none: the main window, else the key window's parent chain.
    public static func defaultParent() -> NSWindow? {
        var window = NSApp.mainWindow ?? NSApp.keyWindow
        while let parent = window?.parent { window = parent }
        return window
    }

    /// The screen a window opened from `parent` belongs on.
    public static func targetScreen(parent: NSWindow?) -> NSScreen? {
        let screens = NSScreen.screens
        let parentScreen = parent?.screen.flatMap { screen in screens.firstIndex { $0 === screen } }
        let mainScreen = NSScreen.main.flatMap { main in screens.firstIndex { $0 === main } }
        let index = screenIndex(test: testScreen, parent: parentScreen ?? mainScreen ?? 0, count: screens.count)
        return index.map { screens[$0] }
    }

    /// Lets Auto Layout resize the window to its content first (a window
    /// whose constraints need more room grows now, not after placement), so
    /// the placed frame is the final one.
    private static func fitToContent(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Places `window` for `parent` (unless it is already on screen) and
    /// orders it in: key and front normally; under no-activate front on
    /// the test screen or behind everything, never key.
    public static func present(_ window: NSWindow, parent: NSWindow? = nil) {
        let parent = parent ?? defaultParent()
        if !window.isVisible, let screen = targetScreen(parent: parent) {
            fitToContent(window)
            let parentFrame = parent?.screen === screen ? parent?.frame : nil
            var cascade = 0
            var frame = Self.frame(size: window.frame.size, parentFrame: parentFrame, visible: screen.visibleFrame)
            // Windows of any height whose top-left corner is taken.
            let taken = NSApp.windows.filter { $0 !== window && $0 !== parent && $0.isVisible }
                .map { CGPoint(x: $0.frame.minX, y: $0.frame.maxY) }
            while taken.contains(CGPoint(x: frame.minX, y: frame.maxY)), cascade < 12 {
                cascade += 1
                frame = Self.frame(size: window.frame.size, parentFrame: parentFrame, visible: screen.visibleFrame, cascade: cascade)
            }
            window.setFrame(frame, display: false)
        }
        WindowActivation.show(window, .present)
    }
}
