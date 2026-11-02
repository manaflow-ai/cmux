import AppKit
@testable import CmuxNextTerminal
import Testing

/// A terminal's scroller is a plain view over the shared thin knob, not a scroll view: on macOS 26 a
/// scroll view tiles its clip view and lays out its scroll-edge pockets on every frame change, and in a
/// split's first frame that pass was the new pane's largest layout item (RESIZE VIDEOS F1).
@MainActor @Suite struct TerminalScrollerResizeTests {
    static func scrollViews(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is NSScrollView || $0 is NSClipView) ? [$0] : scrollViews(in: $0) }
    }

    @Test func aResizedTerminalLaysOutNoScrollView() {
        let host = TerminalHostView()
        host.setFrameSize(NSSize(width: 400, height: 300))
        host.layoutSubtreeIfNeeded()
        #expect(Self.scrollViews(in: host).isEmpty)
    }
}
