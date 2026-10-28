import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// The layout root follows its model through one `FrameObservation` named `Layout.modelSync`
/// (recipe R-obs), not a main-actor `ObservationStream` task: a burst of model
/// changes syncs the view once, in a block of the run loop pass that made them (before that pass
/// commits its frame), and `syncWithModel` applies a pending change in the caller's turn, so the
/// scheduled apply then finds nothing.
@MainActor @Suite(.serialized)
struct LayoutModelSyncTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// One screen of one pane in a borderless window, laid out.
    @MainActor
    final class Fixture {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow

        init() {
            root = LayoutRootView(model: model, contentProvider: Panes(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        /// `panes` panes side by side, written to the model only (no `syncWithModel`).
        func write(panes: Int) {
            var node: SplitNode = .leaf(PaneID("p\(panes)"))
            for index in stride(from: panes - 1, through: 1, by: -1) {
                node = .split(SplitID("h\(index)"), axis: .horizontal, ratio: 0.5, a: .leaf(PaneID("p\(index)")), b: node)
            }
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(node))])
        }

        var screen: ScreenContentView? { root.screenViews["s"] }
    }

    /// Three model writes in one turn reach the view as one sync, on the next run loop pass, not one
    /// sync per write and not inside the writes.
    @Test func aBurstOfModelWritesSyncsTheViewOnceOnTheNextPass() async throws {
        let fixture = Fixture()
        let screen = try #require(fixture.screen)
        let passes = screen.reconcilePasses
        for panes in 2...4 { fixture.write(panes: panes) }
        #expect(screen.paneFrames.count == 1, "the view synced inside a model write")
        #expect(screen.reconcilePasses == passes)
        await drainMainTurns(rounds: 1)
        #expect(screen.paneFrames.count == 4, "the observation did not sync the view on the next pass")
        #expect(screen.reconcilePasses - passes == 1, "\(screen.reconcilePasses - passes) syncs for one burst")
    }

    /// A reader in the change's own turn (the App after a daemon tree) gets the change at once, and
    /// the observation's scheduled apply then lays out nothing more.
    @Test func syncWithModelAppliesThePendingChangeAndTheScheduledApplyFindsNothing() async throws {
        let fixture = Fixture()
        let screen = try #require(fixture.screen)
        fixture.write(panes: 2)
        fixture.root.syncWithModel()
        #expect(screen.paneFrames.count == 2)
        let passes = screen.reconcilePasses
        await drainMainTurns(rounds: 2)
        #expect(screen.reconcilePasses == passes, "the scheduled apply synced the view again")
    }
}
