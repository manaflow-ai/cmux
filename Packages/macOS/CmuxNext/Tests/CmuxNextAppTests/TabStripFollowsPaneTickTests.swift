import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
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
    /// A pane's content view: every size it takes. It answers a pane spring's start with `anchor`, the edge its held
    /// content rides: content that still keeps one size through a key resize (a page until S5, an agent chat). With
    /// `motion.frameOwner.terminals` on, a terminal does not hold: it follows its pane in every frame (cmux-ad m6,
    /// ``aKeyResizeKeepsEachStripAndTerminalOnItsPaneInEveryFrame(direction:)``); with it off (the default until the
    /// flip), it keeps one size per press.
    final class Content: NSView, PaneMotionTargeting {
        var sizes: [CGSize] = []
        var anchor = PaneMotionAnchor.top
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
        func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor { anchor }
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

    /// One screen of `columns` (one column with `node`); the test is the clock.
    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The work the landing left for after its frame's commit, run when the test says.
        var afterCommit: [@MainActor () -> Void] = []

        convenience init(_ node: SplitNode, focused: PaneID) {
            self.init(columns: [LayoutColumn(id: "c0", width: 1, root: node)], focused: focused)
        }

        init(columns: [LayoutColumn], focused: PaneID) {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: focused)
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
        guard let host = rig.root.context.hosts[pane], let view = rig.provider.views[pane] else { return nil }
        return stray(pane, host: host, view: view, content: rig.provider.contents[pane], scale: rig.window.backingScaleFactor)
    }

    /// ``stray(_:in:)`` for `view`, the pane content `host` shows, with `content` below its strip, in a window of `scale`.
    static func stray(_ pane: PaneID, host: PaneHostView, view: PaneContentView, content: NSView?, scale: CGFloat) -> String? {
        guard host.window != nil, !host.isHiddenOrHasHiddenAncestor else { return nil }
        let area = host.convert(host.contentRect, to: nil)
        // A split's new pane before its first frame at a real size.
        guard area.width >= 1, area.height >= 1 else { return nil }
        let strip = view.stripView
        let shown = strip.convert(strip.bounds, to: nil)
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
        if let content {
            let visible = content.convert(content.visibleRect, to: nil)
            if !visible.isEmpty, px(visible.maxY) > px(shown.minY) { off.append("content shows under the strip (up to \(visible.maxY), strip from \(shown.minY))") }
        }
        return off.isEmpty ? nil : "\(pane.rawValue): " + off.joined(separator: "; ")
    }

    // MARK: (b) key resize: red at feat 07b5f411667 (film E1, trace samples 285/286)

    /// One key press: the split's axis, the arrow, and the edge the panes' content asks its held content to ride.
    nonisolated struct KeyPress: Sendable, CustomTestStringConvertible {
        let axis: SplitAxis
        let direction: LayoutDirection
        let anchor: PaneMotionAnchor
        /// The held content rides the bottom edge (a terminal with its prompt on its last row). A case match, not `==`:
        /// the anchor's Equatable conformance is main-actor isolated.
        var ridesBottom: Bool {
            switch anchor {
            case .top: false
            case .bottom: true
            }
        }
        var testDescription: String { "\(axis.rawValue) split, \(direction), content rides the \(ridesBottom ? "bottom" : "top")" }
    }

    /// Ctrl-Shift-H and L on p1 | p2; Ctrl-Shift-K and J on p1 over p2, with terminals whose prompt is on the last row
    /// (their held content rides the bottom edge) and with content that rides the top edge (a page).
    nonisolated static let keyPresses: [KeyPress] = [
        KeyPress(axis: .horizontal, direction: .left, anchor: .bottom), KeyPress(axis: .horizontal, direction: .right, anchor: .bottom),
        KeyPress(axis: .vertical, direction: .up, anchor: .bottom), KeyPress(axis: .vertical, direction: .down, anchor: .bottom),
        KeyPress(axis: .vertical, direction: .up, anchor: .top), KeyPress(axis: .vertical, direction: .down, anchor: .top),
    ]

    /// In every frame of a key resize spring, and at the landing's release, each strip's leading, trailing and top
    /// edges are its pane's, and its tabs are laid out at that width. The content below each strip stays held (RESIZE
    /// KEYS K3): it takes a new size at most once per press, and it never shows under the strip.
    @Test(arguments: keyPresses)
    func aKeyResizeKeepsEachStripOnItsPaneInEveryFrame(_ press: KeyPress) throws {
        let (axis, direction) = (press.axis, press.direction)
        let rig = Rig(.split("x", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), focused: "p2")
        defer { rig.window.closeAfterTest() }
        try #require(rig.provider.views.count == 2)
        try #require(rig.strayStrips("at rest").isEmpty, "\(rig.strayStrips("at rest"))")
        for content in rig.provider.contents.values {
            content.sizes.removeAll()
            content.anchor = press.anchor
        }
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

    /// The key presses whose held content rides the bottom edge (the red cases).
    nonisolated static let heldKeyPresses: [KeyPress] = keyPresses.filter { $0.ridesBottom }

    /// A held key (film px-5fe33a3 P9: the repeats keep the first press's hold through every retarget, 762 px for 1.7 s):
    /// three presses 4 frames apart (a key repeat at about 30 Hz) retarget one spring. In every frame of the chain, and at
    /// its landing's release, each strip is on its pane; the content below each strip lays out at most once for the chain.
    @Test(arguments: heldKeyPresses)
    func aHeldKeyKeepsEachStripOnItsPaneThroughEveryRetarget(_ press: KeyPress) throws {
        let rig = Rig(.split("x", axis: press.axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), focused: "p2")
        defer { rig.window.closeAfterTest() }
        try #require(rig.strayStrips("at rest").isEmpty, "\(rig.strayStrips("at rest"))")
        for content in rig.provider.contents.values {
            content.sizes.removeAll()
            content.anchor = press.anchor
        }
        var strays: [String] = []
        for repeatIndex in 1...2 {
            #expect(PaneResize.press("p2", press.direction, model: rig.model, view: rig.root), "press \(repeatIndex) moved nothing")
            for frame in 1...4 {
                try #require(rig.root.advanceFrame(1.0 / 120), "the spring landed before the next repeat (press \(repeatIndex), frame \(frame))")
                strays += rig.strayStrips("press \(repeatIndex) frame \(frame) tick")
                rig.root.layoutSubtreeIfNeeded()
                strays += rig.strayStrips("press \(repeatIndex) frame \(frame) commit")
            }
        }
        #expect(PaneResize.press("p2", press.direction, model: rig.model, view: rig.root), "press 3 moved nothing")
        let (frames, landing) = rig.runMotion()
        try #require(frames > 3, "the last press did not spring (\(frames) frames)")
        strays += landing.map { "press 3 \($0)" }
        #expect(strays.isEmpty, "\(strays.count) strip frames off their pane in a held key: \(strays.prefix(6))")
        for (pane, content) in rig.provider.contents {
            #expect(content.sizes.count <= 1, "\(pane.rawValue)'s content resized \(content.sizes.count) times in one held key: \(content.sizes.prefix(4))")
        }
    }

    // MARK: (b) with terminals (cmux-ad m6): the strip and the terminal under it follow the pane in every frame

    /// Lawrence on dogfood 363e39f2: "tabbar moves smoothly on ctrl shift hjkl but browsers/terminals do not anymore":
    /// the strip followed its pane (above), the terminal under it kept one size per press (RESIZE KEYS K3's hold). With a
    /// terminal in each pane (the app's pane content, a real Ghostty surface) and one press of each arrow on p2: in every
    /// frame each strip is on its pane; after each frame's layout pass, each terminal host takes its pane's content area
    /// and its surface the size the host shows it at (the text follows the pane); each terminal asks its PTY for one
    /// grid, the final one (the program's size per press). These windows draw nothing, so each size shows at once; with
    /// the window on screen, a size not drawn yet keeps the last frame, top-left (TerminalKeyResizeFrameTests).
    /// Both states of `motion.frameOwner.terminals` (review of #35470, T5): cmux-ad m18 deleted the key hold, so the
    /// surface follows its pane in every frame in both (with it off it took at most one new size per press before); the
    /// switch says only who presents each size's frame. The grid: each PTY ends at its final grid (m18 coalesces the
    /// view's grid, about 25 ms; a synchronous run of frames is one window, so one grid).
    @Test(arguments: [LayoutDirection.left, .right, .up, .down], [false, true])
    func aKeyResizeKeepsEachStripAndTerminalOnItsPaneInEveryFrame(direction: LayoutDirection, switchOn: Bool) async throws {
        typealias Ground = PaneGroundCoversPaneTests
        let vertical = direction == .up || direction == .down
        let rig = Ground.Rig(Ground.column(vertical ? Ground.stack : Ground.pair), focused: "p2")
        defer { rig.close() }
        defer { PaneGroundCoversPaneTests.releaseFrames() }
        let panes: [PaneID] = ["p1", "p2"]
        for pane in panes { _ = try await PaneContentPolicyTests.grids(pane, rig) }
        /// The strips, and with `terminals` each terminal host and surface, against their pane (both states, every frame).
        func off(_ label: String, terminals: Bool, atRest: Bool = false) throws -> [String] {
            var found: [String] = []
            for pane in panes {
                let host = try #require(rig.root.context.hosts[pane])
                let view = try #require(host.content as? PaneContentView, "\(pane) shows no pane content")
                let session = try #require(rig.provider.sessions[pane]?.session)
                let terminal = session.view
                if let stray = Self.stray(pane, host: host, view: view, content: terminal, scale: rig.window.backingScaleFactor) {
                    found.append("\(label): \(stray)")
                }
                guard terminals else { continue }
                let area = try #require(terminal.superview, "\(pane)'s terminal host is not in its pane")
                if terminal.frame.size != area.bounds.size {
                    found.append("\(label): \(pane)'s terminal host \(terminal.frame.size) in \(area.bounds.size)")
                }
                let shown = terminal.surfaceSize(forHostSize: terminal.bounds.size), size = session.surfaceView.frame.size
                if size != shown { found.append("\(label): \(pane)'s surface \(size) in a \(shown) area") }
            }
            return found
        }
        let atRest = try off("at rest", terminals: true, atRest: true)
        try #require(atRest.isEmpty, "\(atRest)")
        let before = try panes.map { try #require(rig.root.context.hosts[$0]).frame }
        try #require(PaneGroundCoversPaneTests.ownFrames(switchOn), "the switch motion.frameOwner.terminals did not take \(switchOn)")
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        var found: [String] = [], frames = 0, moving = true
        while moving, frames < 240 {
            moving = rig.root.advanceFrame(1.0 / 120)
            frames += 1
            found += try off("frame \(frames) tick", terminals: false)
            rig.root.layoutSubtreeIfNeeded()
            found += try off("frame \(frames) commit", terminals: true)
        }
        rig.commit()
        found += try off("after the landing", terminals: true, atRest: true)
        try #require(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(try panes.map { try #require(rig.root.context.hosts[$0]).frame } != before, "the press moved nothing")
        #expect(found.isEmpty, "\(found.count) frames showed a strip or a terminal off its pane: \(found.prefix(6))")
        for pane in panes {
            let grids = try await PaneContentPolicyTests.grids(pane, rig)
            let final = try #require(try PaneContentPolicyTests.surface(pane, in: rig).fittedGrid)
            #expect(grids == [final], "\(pane) asked its PTY for \(grids), not its final grid \(final) once")
        }
    }

    // MARK: (a) split, close, ratio, divider release and column springs: the guard (trace fact 2: the strip follows
    // these springs already)

    enum Spring: String, CaseIterable, Sendable {
        /// Cmd-D on p2: p3 grows in beside it.
        case split
        /// p2 closes: p1 grows to the column's width.
        case close
        /// The split ratio springs from 0.5 to 0.3 (equalize, a width preset, another client's divider drag).
        case ratio
        /// A divider drag's release: the ratio springs on from the pointer's velocity (`SplitMotion.seed`).
        case dividerRelease
        /// Two columns: the first one's width springs from 0.5 to 0.35 of the window, the second one moves.
        case columnWidth
    }

    /// In every frame of a split, a close, a ratio spring, a divider release and a column width spring, each strip's
    /// edges are its pane's and its tabs are laid out at that width, in the tick.
    @Test(arguments: Spring.allCases)
    func aPaneSpringKeepsEachStripOnItsPaneInEveryFrame(_ spring: Spring) throws {
        let rig = spring == .columnWidth
            ? Rig(columns: [LayoutColumn(id: "c0", width: 0.5, root: .leaf("p1")), LayoutColumn(id: "c1", width: 0.5, root: .leaf("p2"))], focused: "p1")
            : Rig(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")), focused: "p2")
        defer { rig.window.closeAfterTest() }
        try #require(rig.strayStrips("at rest").isEmpty, "\(rig.strayStrips("at rest"))")
        switch spring {
        case .split:
            rig.model.apply(screens: [Rig.screen(.split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                                         b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))])
        case .close:
            rig.model.apply(screens: [Rig.screen(.leaf("p1"))])
        case .ratio:
            rig.model.setSplitRatio("x", ratio: 0.3, transaction: .make(), phase: .ended)
        case .dividerRelease:
            // What `DividerDrag` leaves for the layout its release makes: the pointer's velocity, leftward.
            let screen = try #require(rig.root.screenViews["s"])
            screen.releasedDivider = (.split("x"), -900, CACurrentMediaTime(), true)
            rig.model.setSplitRatio("x", ratio: 0.3, transaction: .make(), phase: .ended)
        case .columnWidth:
            rig.model.setColumnWidth("c0", width: 0.35, transaction: .make(), phase: .ended)
        }
        rig.root.syncWithModel()
        let (frames, strays) = rig.runMotion()
        try #require(frames > 3, "the \(spring.rawValue) did not spring (\(frames) frames)")
        #expect(strays.isEmpty, "\(strays.count) strip frames off their pane in \(frames) frames: \(strays.prefix(6))")
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
        // Synchronous from here to the resets: the overrides are process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let enabledAnimations = DesignSettings.shared.enabledAnimations
        DesignSettings.shared.enabledAnimations.insert(.newTab)
        defer { DesignSettings.shared.enabledAnimations = enabledAnimations }
        try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let tabs = (0..<4).map { TabItem(id: TabID("tab\($0)"), title: "python3 /tmp/sigwinch.py --seed 100\($0)") }
        let model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
        // The app's pane content in no window: Core Animation moves a strip only in a window on a screen
        // (`Motion.canAnimate`), a view in no window animates as one on screen does, so the close moves on any host.
        let pane = PaneContentView(stripModel: model, reveal: reveal)
        pane.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        let strip = pane.stripView
        strip.sync(fromModel: true)
        pane.layoutSubtreeIfNeeded()
        model.tabs.removeLast()
        strip.sync(fromModel: true)
        try #require(strip.dying.contains(TabID("tab3")), "the close did not animate")
        let closing = Self.moveGenerations(strip)
        try #require(!closing.isEmpty, "the close started no strip move")
        // The three tabs left share the row between their minimum and maximum widths: their widths follow the strip's.
        try #require(!strip.result.isOverflowing && strip.result.standardWidth < strip.metrics.maxTabWidth - 0.5,
                     "the tabs' widths do not follow the strip's: \(strip.result.standardWidth) pt, overflowing \(strip.result.isOverflowing)")
        let viewport = strip.viewportWidth, widths = strip.result.slots.map(\.width)
        // The pane narrows by 60 pt in one frame.
        pane.setFrameSize(NSSize(width: 420, height: 300))
        pane.layoutSubtreeIfNeeded()
        try #require(strip.viewportWidth < viewport && strip.lastViewportWidth == strip.viewportWidth, "the strip did not lay out at the pane's new width")
        try #require(strip.result.slots.map(\.width) != widths, "the tabs kept their widths: \(widths)")
        let started = Self.moveGenerations(strip).subtracting(closing)
        #expect(started.isEmpty, "the pane's width change started strip moves \(started.sorted()) beside the close's \(closing.sorted())")
        #expect(!Self.moveGenerations(strip).isDisjoint(with: closing), "the close's own move ended when the pane narrowed")
        #expect(strip.cells[TabID("tab3")] != nil, "the closing tab vanished when the pane narrowed")
    }
}
