import AppKit
import CmuxNextBridge
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// `PaneCommitMotionTests`, what the layout reports for the panes that a zoom covers.
///
/// The app reads a pane's presence from the layout: it can take the content of a pane that is reported hidden away
/// (a terminal's surface), and it makes that content again when the pane is reported on the screen, one pane for
/// each frame. A zoom keeps the panes that it covers for the unzoom, and its move shows them until the zoomed pane
/// covers them. So the layout does not report them hidden: not in the move, and not while the zoom has the screen.
extension PaneCommitMotionTests {
    /// The panes whose host shows on `screen` now.
    static func shownPanes(_ screen: ScreenContentView) -> Set<PaneID> {
        Set(paneHosts(screen).filter { !$0.isHidden }.map(\.pane))
    }

    nonisolated static let keepLooks = ["a picture", "opaque"]

    /// A zoom and an unzoom of 30 panes over a window's picture and in an opaque window, read at each frame tick. At
    /// each tick of the zoom's move no pane whose host shows is reported hidden. With the zoom at rest each covered
    /// pane is kept: it is reported in the keep-alive set and not as visible, so it draws nothing and its content
    /// stays. At each tick of the unzoom's move, from the first, each pane of the layout is reported visible. The
    /// zoomed pane gets a content that gives its last frame before the unzoom, so the unzoom moves.
    @Test(arguments: keepLooks)
    func aZoomReportsNoPaneThatItKeepsAsHidden(_ look: String) throws {
        let count = 30
        let harness = Commit.Harness(Commit.screen(Self.tree(count)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        if look != "opaque" { _ = Self.picture(under: harness) }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.paneHosts(screen).filter { !$0.isHidden }
        let all = Set(rest.map(\.pane))
        let far = try #require(rest.max { $0.frame.minX + $0.frame.minY < $1.frame.minX + $1.frame.minY }, "SETUP: the screen shows no pane at rest")
        try #require(all.count == count && harness.model.visiblePanes == all,
                     "SETUP: at rest the screen shows \(all.count) panes and the layout reports \(harness.model.visiblePanes.count) as visible, not \(count)")
        let covered = all.subtracting([far.pane])
        harness.model.focus(far.pane, notify: false)
        Commit.rest(harness)

        harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
        harness.root.syncWithModel()
        var ticks = 0, cut: [String] = []
        repeat {
            _ = harness.root.advanceFrame(Self.dt)
            ticks += 1
            let hidden = Self.shownPanes(screen).subtracting(harness.model.keepAlivePanes)
            if !hidden.isEmpty { cut.append("tick \(ticks): \(hidden.count)") }
        } while Self.inFlight(screen) && ticks < Commit.frames
        try #require(ticks > 1 && !Self.inFlight(screen), "SETUP: the zoom's move had \(ticks) frames")
        #expect(cut.isEmpty, "in the zoom's move the layout reports panes that the screen still shows as hidden (tick: panes): \(cut)")
        Commit.rest(harness)
        let lost = covered.subtracting(harness.model.keepAlivePanes)
        #expect(lost.isEmpty, "with the zoom at rest the layout reports \(lost.count) of the \(covered.count) panes that the zoom keeps as hidden")
        #expect(harness.model.visiblePanes == [far.pane],
                "with the zoom at rest the layout reports \(harness.model.visiblePanes.count) panes as visible, not the zoomed pane alone")

        let content = try #require(harness.provider.contents[far.pane], "SETUP: the zoomed pane has no content")
        let area = PaneContentAreaView(frame: content.bounds), last = Picture(frame: content.bounds)
        area.autoresizingMask = [.width, .height]
        last.autoresizingMask = [.width, .height]
        area.addSubview(last)
        content.addSubview(area)
        harness.model.apply(screens: Commit.screen(Self.tree(count)))
        harness.root.syncWithModel()
        var back = 0, late: [String] = []
        repeat {
            _ = harness.root.advanceFrame(Self.dt)
            back += 1
            let waits = all.subtracting(harness.model.visiblePanes).union(all.subtracting(Self.shownPanes(screen)))
            if !waits.isEmpty { late.append("tick \(back): \(waits.count)") }
        } while Self.inFlight(screen) && back < Commit.frames
        try #require(back > 1 && !Self.inFlight(screen), "SETUP: the unzoom's move had \(back) frames")
        #expect(late.isEmpty, "in the unzoom's move panes of the layout do not show or are not reported visible (tick: panes): \(late)")
        #expect(Self.shownPanes(screen) == all && harness.model.visiblePanes == all, "after the unzoom the screen does not show its \(count) panes as visible")
    }

    /// A zoomed screen that goes out of sight keeps nothing: the layout reports no pane as visible or kept, as for
    /// each other screen that is not seen. In sight again, the zoomed pane is visible and the covered panes are kept.
    @Test func aZoomOutOfSightKeepsNoPane() throws {
        let harness = Commit.Harness(Commit.screen(Self.tree(4)), focused: "p", holds: false) { $0.splitSizingOverride = .even }
        defer { harness.window.closeAfterTest() }
        Self.movePanes(harness)
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let rest = Self.paneHosts(screen).filter { !$0.isHidden }
        let all = Set(rest.map(\.pane))
        let far = try #require(rest.first, "SETUP: the screen shows no pane at rest")
        try #require(all.count == 4 && harness.model.visiblePanes == all, "SETUP: at rest the layout reports \(harness.model.visiblePanes.count) panes as visible, not 4")
        harness.model.focus(far.pane, notify: false)
        Commit.rest(harness)
        harness.model.apply(screens: Commit.screen(.leaf(far.pane), zoomed: true))
        harness.root.syncWithModel()
        Commit.rest(harness)
        try #require(!Self.inFlight(screen) && harness.model.visiblePanes == [far.pane], "SETUP: the zoom did not come to rest with its pane alone visible")

        harness.root.isHidden = true
        harness.root.layoutSubtreeIfNeeded()
        _ = harness.root.advanceFrame(Self.dt)
        #expect(harness.model.keepAlivePanes.isEmpty,
                "out of sight the layout reports \(harness.model.keepAlivePanes.count) panes of a zoomed screen as visible or kept")
        harness.root.isHidden = false
        harness.root.layoutSubtreeIfNeeded()
        _ = harness.root.advanceFrame(Self.dt)
        let lost = all.subtracting(harness.model.keepAlivePanes)
        #expect(harness.model.visiblePanes == [far.pane] && lost.isEmpty,
                "in sight again the layout reports \(harness.model.visiblePanes.count) panes as visible and \(lost.count) of the zoom's panes as hidden")
    }

    /// What the report means for the app's store of terminal surfaces: it closes the surface of a pane that is
    /// reported hidden when more than its count of them are hidden, and a closed one is made new when its pane shows
    /// again. A zoom and an unzoom of 30 panes over a store that keeps 8: with the covered panes reported as kept the
    /// store closes none and each surface is there at the unzoom. The control: reported hidden, it closes 21.
    @Test func theStoreClosesNoSurfaceOfAPaneThatAZoomKeeps() {
        let count = 30, capacity = 8
        func closed(reported covered: SurfacePresence) -> (inTheZoom: Int, atTheUnzoom: Int, gone: Int) {
            var ledger = SurfaceLedger<Int, Int>(capacity: capacity)
            for pane in 0..<count { _ = ledger.present(pane, by: pane, presence: .visible) }
            var zoom = 0, unzoom = 0
            for pane in 1..<count { zoom += ledger.setPresence(covered, owner: pane).evicted.count }
            for pane in 1..<count { unzoom += ledger.setPresence(.visible, owner: pane).evicted.count }
            return (zoom, unzoom, (0..<count).filter { !ledger.isRetained($0) }.count)
        }
        let kept = closed(reported: .keepAlive), hidden = closed(reported: .hidden)
        #expect(kept.inTheZoom == 0 && kept.atTheUnzoom == 0 && kept.gone == 0,
                "with the covered panes kept the store closed \(kept.inTheZoom) surfaces in the zoom and \(kept.atTheUnzoom) at the unzoom; \(kept.gone) are to make new")
        #expect(hidden.inTheZoom == count - 1 - capacity && hidden.gone == hidden.inTheZoom,
                "CONTROL: with the covered panes hidden the store closed \(hidden.inTheZoom) surfaces, not \(count - 1 - capacity); \(hidden.gone) are to make new")
    }
}
