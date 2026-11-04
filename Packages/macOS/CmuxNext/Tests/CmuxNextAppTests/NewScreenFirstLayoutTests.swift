import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// CMD-N LATENCY (cmux-ad m6 2c, 2026-11-04): a Cmd-N workspace's screen is made by the layout sync while its
/// root is already in the window. Its first layout is the sync's own `update(layout:)`; before it, entering the
/// window (`viewDidChangeBackingProperties`, no scale computed yet) and taking the root's size (`setFrameSize`)
/// each ran a whole reconcile first. Every reconcile sets every pane host's frame, and a Chromium page in a pane
/// orders its child window on each frame change (key window change, page focus, WindowServer round trips). On the
/// fleet this was part of the 60-80 ms main-thread stretch after each Cmd-N with no display frame.
/// A new screen lays out once, at the root's size, inside the window.
@MainActor @Suite(.serialized, .closesItsWindows)
struct NewScreenFirstLayoutTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let tree = SplitNode.split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    /// A root in a sized, layer-backed window whose model has no screen yet (a workspace before its tree lands).
    final class Root {
        let panes = Panes()
        let model = LayoutModel()
        let root: LayoutRootView
        let window: NSWindow

        init() {
            root = LayoutRootView(model: model, contentProvider: panes)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }
    }

    @Test func aScreenMadeInTheWindowLaysOutOnceAtTheRootSize() throws {
        let fixture = Root()
        defer { fixture.window.close() }
        #expect(fixture.root.bounds.width == 1200, "the root is sized before the screen comes")

        fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.tree))])
        fixture.root.syncWithModel()

        let screen = try #require(fixture.root.screenViews["s"], "the sync made the screen")
        #expect(screen.window === fixture.window, "the screen is in the window")
        #expect(screen.frame.size == fixture.root.bounds.size, "the screen has the root's size")
        #expect(screen.reconcilePasses == 1, "a new screen reconciled \(screen.reconcilePasses) times in its sync (want 1)")
    }

    @Test func itsFirstLayoutStillHappensWhenTheScreenOnlyTakesItsSize() throws {
        let fixture = Root()
        defer { fixture.window.close() }
        fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Self.tree))])
        fixture.root.syncWithModel()
        let screen = try #require(fixture.root.screenViews["s"])
        let before = screen.reconcilePasses

        // A later window resize still lays the screen out (the guard skips only the passes before the first one).
        fixture.window.setContentSize(NSSize(width: 900, height: 700))
        fixture.root.layoutSubtreeIfNeeded()
        #expect(screen.frame.size == NSSize(width: 900, height: 700))
        #expect(screen.reconcilePasses == before + 1, "a resize after the first layout reconciles once")
    }
}
