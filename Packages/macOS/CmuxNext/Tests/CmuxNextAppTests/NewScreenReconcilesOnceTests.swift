import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// SWITCH STALL 3 (cmux22 xctrace, 2026-11-06): a Cmd-N's `LayoutRootView.sync` (6.6 ms per press) was the new
/// workspace's own screen, flat as the session grew, not a walk of the session. But that one new screen reconciled three
/// times in the sync's turn: when it joined the window (`viewDidChangeBackingProperties`, at viewport zero: every pane
/// host made and placed at a zero rect), when it took the root's size (`setFrameSize`), and from `update(layout:)`. A new
/// screen lays out once, in its window, at its size; the other screens and the hidden workspaces do no work for it.
@MainActor
@Suite(.closesItsWindows)
struct NewScreenReconcilesOnceTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static func screen(_ id: String) -> LayoutScreen {
        LayoutScreen(id: ScreenID(rawValue: id), name: id,
                     layout: .splits(.split(SplitID(rawValue: "\(id)-h"), axis: .horizontal, ratio: 0.5,
                                            a: .leaf(PaneID(rawValue: "\(id)-a")), b: .leaf(PaneID(rawValue: "\(id)-b")))))
    }

    /// One window with `hiddenWorkspaces` parked workspaces (hidden roots of one screen each) and the shown workspace's
    /// root, which holds `screens`.
    final class Fixture {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let hidden: [LayoutRootView]
        let window: NSWindow

        init(screens: [LayoutScreen], hiddenWorkspaces: Int) {
            _ = NSApplication.shared
            let provider = Panes()
            self.provider = provider
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
            window.contentView = container
            hidden = (0..<hiddenWorkspaces).map { index in
                let model = LayoutModel(screens: [NewScreenReconcilesOnceTests.screen("w\(index)")])
                model.followsDesignMetrics = false
                return LayoutRootView(model: model, contentProvider: provider)
            }
            model = LayoutModel(screens: screens, activeScreenID: screens.first?.id)
            model.followsDesignMetrics = false
            root = LayoutRootView(model: model, contentProvider: provider)
            for view in hidden + [root] {
                view.frame = container.bounds
                view.isHidden = view !== root
                container.addSubview(view)
                view.driver.isManual = true
            }
            container.layoutSubtreeIfNeeded()
            settle()
        }

        func settle() {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            window.contentView?.layoutSubtreeIfNeeded()
        }

        /// Reconcile passes of every screen of every workspace in the window.
        func passes() -> [String: Int] {
            var all: [String: Int] = [:]
            for view in hidden + [root] {
                for (id, screen) in view.screenViews { all[id.rawValue] = screen.reconcilePasses }
            }
            return all
        }
    }

    /// Cmd-N: a new workspace's root, already in the window, gets its first screen from the daemon's tree.
    @Test(arguments: [0, 8])
    func aNewWorkspacesFirstScreenReconcilesOnce(hiddenWorkspaces: Int) throws {
        let fixture = Fixture(screens: [], hiddenWorkspaces: hiddenWorkspaces)
        defer { fixture.window.closeAfterTest() }
        let before = fixture.passes()

        fixture.model.apply(screens: [Self.screen("new")])
        fixture.root.syncWithModel()

        let screen = try #require(fixture.root.screenViews["new"])
        #expect(screen.reconcilePasses == 1, "the new workspace's screen reconciled \(screen.reconcilePasses) times in its first sync")
        #expect(screen.frame.size == fixture.root.bounds.size)
        #expect(screen.paneFrames["new-a"]?.targetRect.width ?? 0 > 0, "the first pass did not lay out at the screen's size")
        var after = fixture.passes()
        after["new"] = nil
        #expect(after == before, "a hidden workspace's screens reconciled for another workspace's new screen: \(before) -> \(after)")
    }

    /// A screen added beside `hiddenScreens` hidden ones (and `hiddenScreens` parked workspaces): one pass in all, the new
    /// screen's, and showing it later lays out nothing again.
    @Test(arguments: [0, 8])
    func aScreenAddedBesideHiddenOnesReconcilesOnceInAll(hiddenScreens: Int) throws {
        let screens = (0...hiddenScreens).map { Self.screen("s\($0)") }
        let fixture = Fixture(screens: screens, hiddenWorkspaces: hiddenScreens)
        defer { fixture.window.closeAfterTest() }
        let before = fixture.passes()

        fixture.model.apply(screens: screens + [Self.screen("new")])
        fixture.root.syncWithModel()

        let screen = try #require(fixture.root.screenViews["new"])
        let after = fixture.passes()
        let total = after.reduce(0) { $0 + $1.value - (before[$1.key] ?? 0) }
        #expect(total == 1, "adding one screen beside \(hiddenScreens) hidden ones ran \(total) reconcile passes: \(before) -> \(after)")

        fixture.model.selectScreen("new")
        fixture.root.syncWithModel()
        fixture.settle()
        #expect(screen.reconcilePasses == 1, "showing a screen laid out at its size reconciled it again (\(screen.reconcilePasses) passes)")
    }
}
