import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// A key resize and each pane's content area (`PaneContentAreaView`, FRAME OWNER S1; Lawrence 2026-11-11: "all must have
/// smooth transition"): the content has its area's size in every frame of the spring, is at its final size in the
/// landing's frame, before it hears that the motion ended (a terminal then sizes its surface from its final frame), and
/// takes no other size after it. A chat that draws its tools in the tab row follows its pane the same way (it held whole
/// at its start size before).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneContentAreaHoldTests {
    /// Content that rides the bottom edge (a terminal with its prompt on its last row) and records its frame when it
    /// hears the motion settled.
    class Settling: NSView, PaneMotionTargeting, PaneMotionSettling {
        var settledFrames: [CGRect] = []
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor { .bottom }
        func paneMotionDidSettle() { settledFrames.append(frame) }
    }

    /// A chat that draws its tools in the tab row: its page draws the row, so its area covers the row too.
    final class RowPage: Settling, PaneTabRowSharing {
        var tabRowToolsWidth: CGFloat? { 80 }
        var tabRowToolsNeed: CGFloat? { 80 }
        var onTabRowToolsChange: (() -> Void)?
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {}
    }

    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var contents: [PaneID: Settling] = [:]
        /// Whether each pane shows a chat that draws its tools in the tab row.
        var sharesTabRow = false

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<2).map { TabItem(id: TabID("tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = sharesTabRow ? RowPage() : Settling()
            view.show(content)
            views[pane] = view
            contents[pane] = content
            return view
        }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init(sharesTabRow: Bool = false) {
            _ = NSApplication.shared
            provider.sharesTabRow = sharesTabRow
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        /// One press of `direction` on p2 and the spring to its landing frame; `frame` runs after each frame's layout pass,
        /// the landing's too.
        func press(_ direction: LayoutDirection, frame: (Int) -> Void = { _ in }) throws {
            #expect(PaneResize.press("p2", direction, model: model, view: root))
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                frames += 1
                frame(frames)
            }
            try #require(frames > 3, "the press did not spring (\(frames) frames)")
            root.layoutSubtreeIfNeeded()
            frame(frames + 1)
        }

        /// The landing's after-commit release and one more layout pass.
        func release() {
            let release = afterCommit
            afterCommit.removeAll()
            for work in release { work() }
            root.layoutSubtreeIfNeeded()
        }
    }

    /// A view's rect in its window, to a tenth of a point.
    static func rect(_ view: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: nil)
        func tenth(_ value: CGFloat) -> CGFloat { (value * 10).rounded() / 10 }
        return CGRect(x: tenth(rect.minX), y: tenth(rect.minY), width: tenth(rect.width), height: tenth(rect.height))
    }

    /// The content has its area's rect in every frame of the spring, and at the landing's frame it has its final size:
    /// it hears that the motion ended at that frame, and the release changes nothing.
    @Test(arguments: [LayoutDirection.left, .right])
    func theContentFollowsItsAreaAndIsAtItsFinalSizeWhenItHearsTheLanding(_ direction: LayoutDirection) throws {
        let rig = Rig()
        defer { rig.window.closeAfterTest() }
        let view = try #require(rig.provider.views["p2"]), content = try #require(rig.provider.contents["p2"])
        content.settledFrames.removeAll()
        var off: [String] = []
        var widths: Set<CGFloat> = []
        try rig.press(direction) { frame in
            widths.insert(content.frame.width)
            if content.frame != view.contentHost.bounds { off.append("frame \(frame): \(content.frame) in \(view.contentHost.bounds)") }
            if !view.contentHost.isHolding { off.append("frame \(frame): the area let go before the landing's commit") }
        }
        #expect(off.isEmpty, "the content was not at its area's size during the spring: \(off.prefix(4))")
        #expect(widths.count > 3, "the content did not follow its pane: its widths were \(widths.sorted())")
        let landed = content.frame
        rig.release()
        #expect(!view.contentHost.isHolding, "the hold did not end at the release")
        #expect(content.frame == landed && landed == view.contentHost.bounds,
                "the content changed after the landing's frame: \(content.frame), was \(landed), area \(view.contentHost.bounds)")
        #expect(content.settledFrames == [view.contentHost.bounds],
                "the content heard the landing at \(content.settledFrames), not at its final frame \(view.contentHost.bounds)")
    }

    /// A chat that draws its tools in the tab row: its page draws the row, so its area is its whole pane. It follows its
    /// pane in every frame as any content does (before: its whole view held at its start size until after the landing).
    @Test func aPageThatSharesTheTabRowFollowsItsPaneInEveryFrame() throws {
        let rig = Rig(sharesTabRow: true)
        defer { rig.window.closeAfterTest() }
        let view = try #require(rig.provider.views["p2"]), content = try #require(rig.provider.contents["p2"])
        let host = try #require(rig.root.context.hosts["p2"])
        #expect(view.paneMotionHoldArea === view.contentHost, "a page that draws its tools in the tab row has no area for the key hold")
        var off: [String] = []
        var widths: Set<CGFloat> = []
        try rig.press(.left) { frame in
            let pane = host.convert(host.contentRect, to: nil), area = Self.rect(view.contentHost), shown = Self.rect(content)
            widths.insert(shown.width)
            if shown != area { off.append("frame \(frame): the page at \(shown), its area at \(area)") }
            if abs(area.minX - pane.minX) > 0.11 || abs(area.maxX - pane.maxX) > 0.11 {
                off.append("frame \(frame): the area spans \(area.minX)...\(area.maxX), its pane \(pane.minX)...\(pane.maxX)")
            }
        }
        rig.release()
        #expect(off.isEmpty, "the page was not at its pane's size in \(off.count) frames: \(off.prefix(4))")
        #expect(widths.count > 3, "the page did not follow its pane: its widths were \(widths.sorted())")
        #expect(content.frame == view.contentHost.bounds, "the page is at \(content.frame) after the landing, its area at \(view.contentHost.bounds)")
    }
}
