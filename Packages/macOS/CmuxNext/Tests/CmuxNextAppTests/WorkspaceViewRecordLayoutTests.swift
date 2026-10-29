import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// The layout half of a remount record: `LayoutRootView.scrollRecords` records
/// only cameras a person could have seen, and `restoreScroll`, given before the root is in its
/// window (a remount's order), puts an overflowing row column back at its offset in the first
/// layout pass.
@MainActor
struct WorkspaceViewRecordLayoutTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A root over `screens` (the first shown) in a 1200 x 800 window, laid out and at rest, as
    /// `WorkspaceContentController` mounts one: built out of its window at zero size, then
    /// installed. `restoring` is given before it is installed.
    final class Root {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ screens: [LayoutScreen], focused: PaneID, restoring: [ScreenID: LayoutScreenScroll]? = nil) {
            model = LayoutModel(screens: screens, activeScreenID: screens.first?.id, focusedPane: focused)
            model.rowsEnabledOverride = true
            model.centerFocusedColumnOverride = .never // a focus change scrolls the least that shows its pane
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = false
            if let restoring { root.restoreScroll(restoring) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            settle()
        }

        func settle() { for _ in 0..<600 where root.advanceFrame(1.0 / 120) {} }

        func focus(_ pane: PaneID) {
            model.focus(pane, notify: false)
            root.syncWithModel()
            settle()
        }

        func rowOffset(_ column: ColumnID, on screen: ScreenID = "s") -> CGFloat? {
            root.screenViews[screen]?.rowScrolls[column]?.state.spring.value
        }
    }

    /// `count` half-width columns `<prefix>c1`... of one pane `<prefix>1`... each.
    static func columns(_ prefix: String, _ count: Int) -> ScreenLayout {
        .columns((1...count).map { LayoutColumn(id: ColumnID("\(prefix)c\($0)"), width: 0.5, root: .leaf(PaneID("\(prefix)\($0)"))) })
    }

    /// One full-width column `c1` of `heights.count` rows (permille each), as the daemon sends it:
    /// the rows, and the compat chain of vertical splits that holds every pane.
    static func rows(_ heights: [Int]) -> ScreenLayout {
        let rows = heights.enumerated().map { index, height in
            LayoutRow(id: RowID("r\(index + 1)"), height: height, root: .leaf(PaneID("p\(index + 1)")))
        }
        func chain(_ rest: ArraySlice<LayoutRow>) -> SplitNode {
            guard rest.count > 1, let first = rest.first else { return rest.first!.root }
            return .split(SplitID("v\(first.id.rawValue)"), axis: .vertical, ratio: 1 / Double(rest.count), a: first.root,
                          b: chain(rest.dropFirst()))
        }
        return .columns([LayoutColumn(id: "c1", width: 1, root: chain(rows[...]), rows: rows)])
    }

    /// A screen the person never showed in this mount was laid out only at zero size (built while
    /// its root had none, hidden since): its reducers placed a camera against a zero viewport. The
    /// record leaves it out, so a remount places that screen as a fresh mount does.
    @Test func aScreenNeverShownRecordsNoCamera() {
        let shown = LayoutScreen(id: "s", name: "s", layout: Self.columns("p", 3))
        let hidden = LayoutScreen(id: "t", name: "t", layout: Self.columns("q", 3))
        let mount = Root([shown, hidden], focused: "p3")
        let records = mount.root.scrollRecords()
        #expect((records["s"]?.strip ?? 0) > 100, "the shown strip did not scroll to p3: \(String(describing: records["s"]))")
        #expect(records["t"] == nil, "a screen laid out only at zero size recorded a camera: \(String(describing: records["t"]))")
    }

    @Test func anOverflowingRowColumnComesBackAtItsOffset() throws {
        let screen = LayoutScreen(id: "s", name: "s", layout: Self.rows([400, 400, 400, 400]))
        let first = Root([screen], focused: "p4")
        // The rows scroll to the end for p4; focusing p2 then scrolls back the least that shows it.
        first.focus("p2")
        let offset = try #require(first.rowOffset("c1"))
        let records = first.root.scrollRecords()
        let saved = try #require(records["s"]?.rows["c1"])
        #expect(abs(saved - offset) < 0.5, "the record says \(saved), the rows rest at \(offset)")

        let fresh = Root([screen], focused: "p2")
        #expect(abs((fresh.rowOffset("c1") ?? 0) - offset) > 50, "a fresh mount already rests at \(offset): the fixture proves nothing")

        let remount = Root([screen], focused: "p2", restoring: records)
        let restored = try #require(remount.rowOffset("c1"), "the remount's column does not scroll")
        #expect(abs(restored - offset) < 0.5, "the remount's rows rest at \(restored), not \(offset)")
        #expect(remount.root.screenViews["s"]?.rowScrolls["c1"]?.state.spring.target == restored, "the restore moved on frames")
    }
}
