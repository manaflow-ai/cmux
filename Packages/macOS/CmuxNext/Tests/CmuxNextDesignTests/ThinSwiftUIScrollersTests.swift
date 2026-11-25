import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import SwiftUI
import Testing

/// SwiftUI scroll views take the shared thin scroller too (SCROLLBARS-THIN, Leo 2026-10-12): on
/// macOS a SwiftUI `ScrollView` is an NSScrollView that follows the system's "Show scroll bars"
/// setting, so with "Always" Tasks, Feed, Apps, Bookmarks and Debug Settings drew a gray track.
/// With `.thinScrollers()` on its content, the scroll view is overlay, and stays overlay when
/// AppKit resets it to the system's style on a change of the setting. The same for a `List`.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct ThinSwiftUIScrollersTests {
    @Test func aSwiftUIScrollViewStaysOverlayWhenTheSystemSaysAlways() throws {
        try expectOverlay(ScrollView {
            VStack { ForEach(0..<60, id: \.self) { Text("Row \($0)") } }.thinScrollers()
        })
    }

    /// A SwiftUI `List` (History, Bookmarks) is a table in an NSScrollView; its rows take it.
    @Test func aSwiftUIListStaysOverlayWhenTheSystemSaysAlways() throws {
        try expectOverlay(List {
            ForEach(0..<60, id: \.self) { Text("Row \($0)").thinScrollers() }
        })
    }

    private func expectOverlay(_ content: some View) throws {
        let host = NSHostingView(rootView: content.frame(width: 240, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let scrollView = try #require(Self.scrollView(in: host))
        // What AppKit does to every scroll view when the setting becomes "Always".
        scrollView.scrollerStyle = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(scrollView.scrollerStyle == .overlay)
        window.contentView = nil
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}
