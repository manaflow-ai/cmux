import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5): each `debug.mouse` move set the synthesized pointer, then walked every view
/// of the window to find its layouts (`LayoutRootView.setDebugPointer`). A STRESS window has thousands of views: about
/// 1 ms of main thread per move, in every frame of a drag bench (Time Profiler of job ed08902c: 1.0-1.75 ms per frame
/// in the drag rows), which a person's drag never pays. The layouts that take a pointer are the live ones; the move
/// refreshes those and asks no other view anything.
@MainActor @Suite(.closesItsWindows)
struct DebugPointerLayoutLookupTests {
    /// Counts the reads of its subviews (a walk of the window reads every view's).
    final class CountingView: NSView {
        static var subviewReads = 0
        override var subviews: [NSView] {
            get {
                Self.subviewReads += 1
                return super.subviews
            }
            set { super.subviews = newValue }
        }
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func aDebugPointerMoveRefreshesTheLayoutWithoutWalkingTheWindowsViews() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        let content = try #require(window.contentView)
        // Chrome beside the layout (a sidebar and its rows): views a pointer move has no business with.
        let sidebar = CountingView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        content.addSubview(sidebar)
        for index in 0..<300 { sidebar.addSubview(CountingView(frame: NSRect(x: 0, y: CGFloat(index) * 2, width: 200, height: 2))) }
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.frame = NSRect(x: 200, y: 0, width: 1000, height: 800)
        content.addSubview(root)
        root.layoutSubtreeIfNeeded()
        try #require(root.isLive, "the layout is not live in its window")
        let divider = try #require(root.debugDividerCenter(named: "first"), "the split shows no divider")
        defer { PointerHover.debugPointers[ObjectIdentifier(window)] = nil }

        CountingView.subviewReads = 0
        LayoutRootView.setDebugPointer(divider, in: window)
        #expect(CountingView.subviewReads == 0,
                "one debug.mouse move asked the sidebar's views for their subviews \(CountingView.subviewReads) times (want 0)")
        // The move still reached the layout: the divider under the synthesized pointer hovers.
        let screen = try #require(root.screenViews.values.first)
        let hovered = screen.dividerViews.values.contains { $0.isHovered }
        #expect(hovered, "the divider under the synthesized pointer does not hover")
    }
}
