import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// The shell window sets AppKit's full-screen tile sizes (`minFullScreenContentSize`, `maxFullScreenContentSize`) from
/// its own minimum size, so AppKit never measures its views for them. AppKit asks after each change of the window's
/// views (a run loop observer, `_doUpdateTilingConstraintsImmediately`), and its own answer walked every view's
/// constraints: about 3 ms of the main thread after each new tab, workspace or pane in a fleet sample (CMUX NEXT Stable
/// perf gate, 2026-11-27).
@MainActor @Suite(.serialized, .closesItsWindows) struct ShellWindowTileMinimumTests {
    /// Counts AppKit's full-screen minimum-size walk reaching it (`-[NSView _willMeasureMinSizeForFullscreen]`).
    final class CountingView: NSView {
        static var measured = 0
        @objc func _willMeasureMinSizeForFullscreen() { Self.measured += 1 }
    }

    private static let content = CGRect(x: 200, y: 200, width: 1_000, height: 600)
    private static let walk = NSSelectorFromString("_willMeasureMinSizeForFullscreen")
    private static let tilingUpdate = NSSelectorFromString("_doUpdateTilingConstraintsImmediately")

    /// A shell window whose content's constraints ask for 900 pt, more than the window's 520 pt minimum.
    private func window() -> (ShellWindow, NSLayoutConstraint) {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: Self.content, styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        let root = NSView(frame: CGRect(origin: .zero, size: Self.content.size))
        window.contentView = root
        let wide = CountingView()
        wide.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(wide)
        let width = wide.widthAnchor.constraint(greaterThanOrEqualToConstant: 900)
        NSLayoutConstraint.activate([
            width,
            wide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            wide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            wide.topAnchor.constraint(equalTo: root.topAnchor),
            wide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        return (window, width)
    }

    @Test func aChangeOfTheViewsMeasuresNothingForTheTileSizes() {
        // The walk this test counts is still AppKit's: renamed, the count would stay 0 whatever the window does.
        #expect(NSView.instancesRespond(to: Self.walk), "AppKit's full-screen measure walk was renamed: re-check this test")
        let (window, width) = window()
        defer { window.close() }
        width.constant = 950 // a change of the window's views: AppKit forgets any size it measured
        window.contentView?.layoutSubtreeIfNeeded()
        CountingView.measured = 0
        #expect(window.minFullScreenContentSize == NSSize(width: 520, height: 320))
        #expect(window.maxFullScreenContentSize.width >= Self.content.width)
        #expect(window.responds(to: Self.tilingUpdate), "AppKit's tiling update was renamed: re-check what it measures")
        if window.responds(to: Self.tilingUpdate) { _ = window.perform(Self.tilingUpdate) }
        #expect(CountingView.measured == 0, "AppKit measured the window's views \(CountingView.measured) times for its tile sizes")
    }

    @Test func aSetTileMinimumIsKeptUntilTheWindowsMinimumChanges() {
        let (window, _) = window()
        defer { window.close() }
        window.minFullScreenContentSize = NSSize(width: 700, height: 400)
        #expect(window.minFullScreenContentSize == NSSize(width: 700, height: 400))
        window.minSize = NSSize(width: 600, height: 360)
        #expect(window.minFullScreenContentSize == NSSize(width: 600, height: 360))
    }
}
