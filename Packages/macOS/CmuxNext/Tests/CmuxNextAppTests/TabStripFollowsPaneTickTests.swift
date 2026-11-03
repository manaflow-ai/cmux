import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1 (Lawrence, P0: "the tabbar is not perfectly in sync with the animation").
///
/// Film resize-keyboard (FEAT DOGFOOD BUILD 1d8e759e, feat 5fe33a327efd, frames 244-270, still E1): in a key resize
/// (Ctrl-Shift-L) the shrinking pane's tab strip stays where it was for the whole spring, the moving pane edge cuts it
/// ("python3" -> "on3"), and the whole tab jumps 115 px 3-4 frames after the pane edge rests. Trace of the same round:
/// at the landing's release the strip has its new x but its old width; its width follows one tick later. Cause: the
/// key-resize hold (RESIZE KEYS K3, `PaneHostView.contentFrame(in:)`) holds the pane's whole content view, and the
/// strip is part of it.
///
/// The rule: when a pane's geometry moves, its strip lays out from the pane's width of the same frame tick, in that
/// tick, and only the content area below the strip may be held. A width change that pane motion causes starts no strip
/// move of its own (`TabStripMove`, a 200 ms render-server tween on another clock); a tab close in flight keeps its
/// own move.
///
/// The panes show the app's own pane content (`PaneContentView`: a tab strip over its content host); the frames step at
/// a fixed 120 Hz dt and the landing's after-commit work runs when the test says (`LayoutViewContext.afterCommit`).
/// Each frame is checked right after its tick (what the tick itself laid out) and again after the window's layout
/// pass (what that frame's commit shows).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabStripFollowsPaneTickTests {
    /// The stage's Debug switch, by its key: these tests turn it on, whatever its default.
    static let frameOwnerSwitch = "motion.frameOwner.tabStrip"

    /// Runs `body` with the switch on, then resets it.
    static func withFrameOwnerSwitch(_ body: () throws -> Void) rethrows {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register([TunableDescriptor(key: frameOwnerSwitch, section: .springs, label: "Tab strip follows the pane tick",
                                          help: "FRAME OWNER REFACTOR S1 test switch.", kind: .bool, defaultSource: .fixed(.bool(true)))])
        store.set(frameOwnerSwitch, .bool(true))
        defer { store.set(frameOwnerSwitch, nil) }
        try body()
    }

    /// A pane's content view: every size it takes.
    final class Content: NSView {
        var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    /// Each pane shows the app's pane content: three tabs over a content view.
    final class Panes: LayoutPaneContentProvider {
        /// Every launch region ready: nothing is held for launch.
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var views: [PaneID: PaneContentView] = [:]
        var contents: [PaneID: Content] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let view = PaneContentView(stripModel: TabStripModel(tabs: tabs, selectedID: tabs[0].id), reveal: reveal)
            let content = Content()
            view.show(content)
            views[pane] = view
            contents[pane] = content
            return view
        }
    }

    /// One column with `root`; the test is the clock.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The work the landing left for after its frame's commit, run when the test says.
        var afterCommit: [@MainActor () -> Void] = []

        init(_ node: SplitNode, focused: PaneID) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [Self.screen(node)], activeScreenID: "s", focusedPane: focused)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // What joined the window in that pass (each pane's strip syncs its tabs then) lays out in this one.
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        static func screen(_ node: SplitNode) -> LayoutScreen {
            LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: "c0", width: 1, root: node)]))
        }

        /// Where each shown pane's strip is not on its pane, in the frame `label` names.
        func strayStrips(_ label: String) -> [String] {
            provider.views.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { pane in
                TabStripFollowsPaneTickTests.stray(pane, in: self).map { "\(label): \($0)" }
            }
        }

        /// Steps the motion to its landing. Each frame is checked after its tick and after the window's layout pass;
        /// the landing's release is checked before and after the layout pass that follows it. Returns the frames that
        /// moved and every stray strip seen.
        func runMotion() -> (frames: Int, strays: [String]) {
            var frames = 0, strays: [String] = [], moving = true
            while moving, frames < 240 {
                moving = root.advanceFrame(1.0 / 120)
                frames += 1
                strays += strayStrips("frame \(frames) tick")
                root.layoutSubtreeIfNeeded()
                strays += strayStrips("frame \(frames) commit")
            }
            let release = afterCommit
            afterCommit.removeAll()
            for work in release { work() }
            strays += strayStrips("landing release")
            root.layoutSubtreeIfNeeded()
            strays += strayStrips("after the release's layout pass")
            return (frames, strays)
        }
    }

    /// Where `pane`'s strip is not where its pane is now, in device pixels of the window; nil when it is. The strip
    /// (no toolbar, no tab-row tools here) spans the pane's content rect (`PaneHostView.contentRect`, the padded rect the
    /// content view fills) and sits at its top; its tabs were laid out at the width it shows; the content below it
    /// never shows under it.
    static func stray(_ pane: PaneID, in rig: Rig) -> String? {
        guard let host = rig.root.context.hosts[pane], host.window != nil, !host.isHiddenOrHasHiddenAncestor,
              let view = rig.provider.views[pane] else { return nil }
        let area = host.convert(host.contentRect, to: nil)
        // A split's new pane before its first frame at a real size.
        guard area.width >= 1, area.height >= 1 else { return nil }
        let strip = view.stripView
        let shown = strip.convert(strip.bounds, to: nil)
        let scale = rig.window.backingScaleFactor
        func px(_ value: CGFloat) -> Int { Int((value * scale).rounded()) }
        var off: [String] = []
        if px(shown.minX) != px(area.minX) { off.append("leading edge \(shown.minX) vs pane \(area.minX)") }
        if px(shown.maxX) != px(area.maxX) { off.append("trailing edge \(shown.maxX) vs pane \(area.maxX)") }
        if px(shown.maxY) != px(area.maxY) { off.append("top \(shown.maxY) vs pane \(area.maxY)") }
        if strip.needsLayout { off.append("its frame changed, its tabs were not laid out") }
        // The tabs' area at the width the strip shows (a strip narrower than its paddings has an empty one).
        let tabs = strip.tabsClip.convert(strip.tabsClip.bounds, to: nil)
        if tabs.width > 0, px(tabs.minX) < px(shown.minX) || px(tabs.maxX) > px(shown.maxX) {
            off.append("tabs laid out at \(tabs.minX)...\(tabs.maxX), past the strip's \(shown.minX)...\(shown.maxX)")
        }
        if let content = rig.provider.contents[pane] {
            let visible = content.convert(content.visibleRect, to: nil)
            if !visible.isEmpty, px(visible.maxY) > px(shown.minY) { off.append("content shows under the strip (up to \(visible.maxY), strip from \(shown.minY))") }
        }
        return off.isEmpty ? nil : "\(pane.rawValue): " + off.joined(separator: "; ")
    }

    // MARK: (b) key resize: red at feat 07b5f411667 (film E1, trace samples 285/286)

    /// Ctrl-Shift-H/L on p1 | p2 and Ctrl-Shift-K/J on p1 over p2: in every frame of the spring, and at the landing's
    /// release, each strip's leading, trailing and top edges are its pane's, and its tabs are laid out at that width. The
    /// content below each strip stays held (RESIZE KEYS K3): it takes a new size at most once per press.
    @Test(arguments: zip([SplitAxis.horizontal, .horizontal, .vertical, .vertical], [LayoutDirection.left, .right, .up, .down]))
    func aKeyResizeKeepsEachStripOnItsPaneInEveryFrame(axis: SplitAxis, direction: LayoutDirection) throws {
        try Self.withFrameOwnerSwitch {
            let rig = Rig(.split("x", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), focused: "p2")
            defer { rig.window.closeAfterTest() }
            try #require(rig.provider.views.count == 2)
            try #require(rig.strayStrips("at rest").isEmpty, "\(rig.strayStrips("at rest"))")
            for content in rig.provider.contents.values { content.sizes.removeAll() }
            let before = (rig.root.context.hosts["p1"]?.frame, rig.root.context.hosts["p2"]?.frame)
            #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
            rig.root.syncWithModel()
            let (frames, strays) = rig.runMotion()
            try #require(frames > 3, "the press did not spring (\(frames) frames)")
            #expect(rig.root.context.hosts["p1"]?.frame != before.0 && rig.root.context.hosts["p2"]?.frame != before.1, "the press moved nothing")
            #expect(strays.isEmpty, "\(strays.count) strip frames off their pane in \(frames) frames: \(strays.prefix(6))")
            for (pane, content) in rig.provider.contents {
                #expect(content.sizes.count <= 1, "\(pane.rawValue)'s content resized \(content.sizes.count) times in one key press: \(content.sizes.prefix(4))")
            }
        }
    }

    // MARK: (a) split, close and ratio springs: the guard (trace fact 2: the strip follows these springs already)

    enum Spring: String, CaseIterable, Sendable {
        /// Cmd-D on p2: p3 grows in beside it.
        case split
        /// p2 closes: p1 grows to the column's width.
        case close
        /// The split ratio springs from 0.5 to 0.3 (equalize, a width preset, a released divider's snap).
        case ratio
    }

    /// In every frame of a split, a close and a ratio spring, each strip's edges are its pane's and its tabs are laid
    /// out at that width, in the tick.
    @Test(arguments: Spring.allCases)
    func aPaneSpringKeepsEachStripOnItsPaneInEveryFrame(_ spring: Spring) throws {
        try Self.withFrameOwnerSwitch {
            let rig = Rig(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), focused: "p2")
            defer { rig.window.closeAfterTest() }
            try #require(rig.strayStrips("at rest").isEmpty, "\(rig.strayStrips("at rest"))")
            let next: SplitNode = switch spring {
            case .split: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
            case .close: .leaf("p1")
            case .ratio: .split("x", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))
            }
            rig.model.apply(screens: [Rig.screen(next)])
            rig.root.syncWithModel()
            let (frames, strays) = rig.runMotion()
            try #require(frames > 3, "the \(spring.rawValue) did not spring (\(frames) frames)")
            #expect(strays.isEmpty, "\(strays.count) strip frames off their pane in \(frames) frames: \(strays.prefix(6))")
        }
    }

    // MARK: (c) no strip move for a width change: red at feat 07b5f411667 with ui.animations.newTab on

    /// The generations of the strip moves on the cells' layers (`TabStripMove` keys: "tab.move.<generation>.<part>").
    static func moveGenerations(_ strip: TabStripView) -> Set<Int> {
        var found: Set<Int> = []
        for cell in strip.cells.values {
            for key in cell.layer.animationKeys() ?? [] where key.hasPrefix(TabStripMove.keyPrefix) {
                if let generation = key.dropFirst(TabStripMove.keyPrefix.count).split(separator: ".").first.flatMap({ Int($0) }) {
                    found.insert(generation)
                }
            }
        }
        return found
    }

    /// A tab closes on its own tween (`ui.animations.newTab` on), and while it closes the pane narrows (a split, a close
    /// or a key resize moves its edge): only the strip's width changed. The width change starts no strip move: the tabs
    /// take the new width in the frame the pane does, and the close keeps its own move and its closing tab
    /// (cx-y2uf5: the closing tab never vanishes when the strip's width changes).
    @Test func aPaneWidthChangeStartsNoStripMoveWhileATabCloses() throws {
        try Self.withFrameOwnerSwitch {
            // Synchronous from here to the resets: the overrides are process-wide.
            Motion.reduceMotionOverride = false
            defer { Motion.reduceMotionOverride = nil }
            let enabledAnimations = DesignSettings.shared.enabledAnimations
            DesignSettings.shared.enabledAnimations.insert(.newTab)
            defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
            try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")
            let reveal = LaunchReveal()
            reveal.markAllReady()
            let tabs = (0..<8).map { TabItem(id: TabID("tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
            let model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
            // The app's pane content in no window: Core Animation moves a strip only in a window on a screen
            // (`Motion.canAnimate`), a view in no window animates as one on screen does, so the close moves on any host.
            let pane = PaneContentView(stripModel: model, reveal: reveal)
            pane.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
            let strip = pane.stripView
            strip.sync(fromModel: true)
            pane.layoutSubtreeIfNeeded()
            // Eight tabs share the row: their widths follow the strip's.
            try #require(strip.result.standardWidth < strip.metrics.maxTabWidth - 0.5, "the tabs are not narrowed: \(strip.result.standardWidth)")
            model.tabs.removeLast()
            strip.sync(fromModel: true)
            try #require(strip.dying.contains(TabID("tab7")), "the close did not animate")
            let closing = Self.moveGenerations(strip)
            try #require(!closing.isEmpty, "the close started no strip move")
            let viewport = strip.viewportWidth
            // The pane narrows by 40 pt in one frame.
            pane.setFrameSize(NSSize(width: 440, height: 300))
            pane.layoutSubtreeIfNeeded()
            try #require(strip.viewportWidth < viewport && strip.lastViewportWidth == strip.viewportWidth, "the strip did not lay out at the pane's new width")
            let started = Self.moveGenerations(strip).subtracting(closing)
            #expect(started.isEmpty, "the pane's width change started strip moves \(started.sorted()) beside the close's \(closing.sorted())")
            #expect(!Self.moveGenerations(strip).isDisjoint(with: closing), "the close's own move ended when the pane narrowed")
            #expect(strip.cells[TabID("tab7")] != nil, "the closing tab vanished when the pane narrowed")
        }
    }
}
