import AppKit
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// The shell window answers AppKit's full-screen tile minimum (`minFullScreenContentSize`) from its own minimum size,
/// never by measuring its views. AppKit asks after each change of the window's views (a run loop observer,
/// `_doUpdateTilingConstraintsImmediately`), and its own answer walked every view's constraints: about 3 ms of the main
/// thread after each new tab, workspace or pane in a fleet sample (CMUX NEXT Stable perf gate, 2026-11-27).
@MainActor @Suite(.serialized, .closesItsWindows) struct ShellWindowTileMinimumTests {
    /// Counts AppKit's full-screen minimum-size walk reaching it (`-[NSView _willMeasureMinSizeForFullscreen]`).
    final class CountingView: NSView {
        static var measured = 0
        @objc func _willMeasureMinSizeForFullscreen() { Self.measured += 1 }
    }

    private static let content = CGRect(x: 200, y: 200, width: 1_000, height: 600)

    /// A shell window whose content's constraints ask for 900 pt, more than the window's 520 pt minimum.
    private func window() -> (ShellWindow, CountingView) {
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
        NSLayoutConstraint.activate([
            wide.widthAnchor.constraint(greaterThanOrEqualToConstant: 900),
            wide.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            wide.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            wide.topAnchor.constraint(equalTo: root.topAnchor),
            wide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        return (window, wide)
    }

    @Test func theTileMinimumIsTheWindowsOwnMinimumNotAMeasureOfItsViews() {
        let (window, _) = window()
        defer { window.close() }
        CountingView.measured = 0
        #expect(window.minFullScreenContentSize == NSSize(width: 520, height: 320))
        #expect(CountingView.measured == 0, "AppKit measured the window's views \(CountingView.measured) times for its tile minimum")
    }

    @Test func aSetTileMinimumIsKept() {
        let (window, _) = window()
        defer { window.close() }
        window.minFullScreenContentSize = NSSize(width: 700, height: 400)
        #expect(window.minFullScreenContentSize == NSSize(width: 700, height: 400))
    }
}
