import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3: the shell color never shows inside a pane rect, in any frame, for any entry point. Fixture
/// films (ROOT-CAUSE.md P9-P12, shell #FF00FF): a key press opens a shell band of up to 116 px inside the growing pane,
/// held keys up to 762 px for 1.7 s, a pane close a 710 px hole and a column close a 530 px one.
///
/// The rule, from the view tree at every manual 120 Hz tick: each pane's own ground (for a terminal, its terminal host,
/// which paints the terminal's ground and padding) covers the pane's content area (`PaneHostView.roundedRect`: the pane
/// less its padding and tab strip), and a closed pane's place is covered by pane hosts until its neighbours cover it.
/// A miss names the first layer, from the pane host down to the ground, that stops short of the area. A divider drag
/// already follows (the surface keeps its size inside a host that follows): a guard. A page's own pixels are S5's.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneGroundCoversPaneTests {
    /// Each pane shows the app's pane content with a terminal in it.
    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var sessions: [PaneID: (session: TerminalSession, io: GridRecordingTerminalIO)] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let io = GridRecordingTerminalIO()
            let session = TerminalSession(io: io)
            let view = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("terminal"), title: "zsh")]), reveal: reveal)
            view.show(session.view)
            sessions[pane] = (session, io)
            return view
        }
    }

    final class Rig {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var afterCommit: [@MainActor () -> Void] = []

        init(_ layout: ScreenLayout, focused: PaneID) {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
            model.followsDesignMetrics = false
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            root.context.afterCommit = { [unowned self] in self.afterCommit.append($0) }
        }

        var screen: ScreenContentView { get throws { try #require(root.screenViews["s"]) } }

        /// One display frame and the window's layout pass after it; false once nothing moves.
        func frame() -> Bool {
            let moving = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            return moving
        }

        func commit() {
            let work = afterCommit
            afterCommit.removeAll()
            for item in work { item() }
            root.layoutSubtreeIfNeeded()
        }

        func close() {
            for (session, io) in provider.sessions.values {
                session.close()
                io.finish()
            }
            window.closeAfterTest()
        }

        /// Every live pane whose ground leaves part of its content area uncovered now, by more than `slack` points.
        func misses(slack: CGFloat = 1) -> [String] {
            root.context.hosts.compactMap { entry -> String? in
                let (pane, host) = (entry.key, entry.value)
                guard host.superview != nil, !host.isHidden, host.alphaValue > 0.01, host.bounds.width >= 1,
                      let ground = provider.sessions[pane]?.session.view else { return nil }
                return PaneGroundCoversPaneTests.miss(pane, host: host, ground: ground, slack: slack)
            }.sorted()
        }

        /// The union of the shown pane hosts (live or closing) along the horizontal line through `rect`'s middle: what of
        /// `rect`'s width no pane covers, in points.
        func uncoveredWidth(of rect: CGRect) throws -> CGFloat {
            let hosts = try screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden && $0.alphaValue > 0.01 }
            var gaps = [(rect.minX, rect.maxX)]
            for host in hosts {
                let shown = host.convert(host.bounds, to: nil)
                guard shown.minY <= rect.midY, shown.maxY >= rect.midY else { continue }
                gaps = gaps.flatMap { gap -> [(CGFloat, CGFloat)] in
                    [(gap.0, min(gap.1, shown.minX)), (max(gap.0, shown.maxX), gap.1)].filter { $0.1 - $0.0 > 0 }
                }
            }
            return gaps.reduce(0) { $0 + ($1.1 - $1.0) }
        }
    }

    /// Where `view` shows in the window: its frame cut by every ancestor up to `host` that clips its sublayers.
    static func shown(_ view: NSView, in host: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let next = ancestor {
            if next.layer?.masksToBounds == true { rect = rect.intersection(next.convert(next.bounds, to: nil)) }
            if next === host { break }
            ancestor = next.superview
        }
        return rect
    }

    /// Nil when `ground` covers `host`'s content area; else what is uncovered, and the first layer from the host down to
    /// the ground that stops short of the area.
    static func miss(_ pane: PaneID, host: PaneHostView, ground: NSView, slack: CGFloat) -> String? {
        let area = host.convert(host.roundedRect, to: nil)
        func short(_ rect: CGRect) -> (lead: CGFloat, trail: CGFloat, bottom: CGFloat, top: CGFloat) {
            guard !rect.isNull, !rect.isEmpty else { return (area.width, area.width, area.height, area.height) }
            return (max(0, rect.minX - area.minX), max(0, area.maxX - rect.maxX), max(0, rect.minY - area.minY), max(0, area.maxY - rect.maxY))
        }
        let gap = short(shown(ground, in: host))
        guard max(gap.lead, gap.trail, gap.bottom, gap.top) > slack else { return nil }
        var chain: [NSView] = []
        var view: NSView? = ground
        while let next = view, next !== host {
            chain.insert(next, at: 0)
            view = next.superview
        }
        let culprit = chain.first { view in
            let s = short(shown(view, in: host))
            return max(s.lead, s.trail, s.bottom, s.top) > slack
        } ?? ground
        let r = shown(culprit, in: host)
        return "\(pane): \(String(format: "%.1f", gap.lead)) pt leading, \(String(format: "%.1f", gap.trail)) trailing, "
            + "\(String(format: "%.1f", gap.bottom)) bottom, \(String(format: "%.1f", gap.top)) top of its content area "
            + "x \(Int(area.minX))..\(Int(area.maxX)) y \(Int(area.minY))..\(Int(area.maxY)) show no ground of its own: the first layer short of it is "
            + "\(type(of: culprit)) at x \(Int(r.minX))..\(Int(r.maxX)) y \(Int(r.minY))..\(Int(r.maxY))"
    }

    nonisolated static let pair: SplitNode = .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    nonisolated static let stack: SplitNode = .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    static func column(_ root: SplitNode) -> ScreenLayout { .columns([LayoutColumn(id: "c0", width: 1, root: root)]) }

    /// (a) One Ctrl-Shift-H/L/K/J press on p2: at every tick, each pane's terminal ground covers its content area. In both
    /// states of `motion.frameOwner.terminals` (review of #35470, T5).
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aKeyPressShowsEachPanesOwnGroundInEveryFrame(direction: LayoutDirection) throws {
        let rig = Rig(Self.column(direction == .left || direction == .right ? Self.pair : Self.stack), focused: "p2")
        defer { rig.close() }
        #expect(rig.misses().isEmpty, "SETUP: at rest a pane's ground does not cover it: \(rig.misses())")
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        #expect(try rig.screen.holdsContentForKeyResize, "the press did not hold the pane contents (K3)")
        var found: [String] = rig.misses().map { "key turn: \($0)" }
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            found += rig.misses().map { "frame \(frames): \($0)" }
        }
        rig.commit()
        found += rig.misses().map { "after the landing commit: \($0)" }
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(found.isEmpty, "\(found.count) pane frames show no ground of their own (the shell shows there); first: \(found.prefix(3)), last: \(found.suffix(1))")
    }

    /// (b) A held key: three Ctrl-Shift-L presses 4 frames apart retarget one spring. In both states of
    /// `motion.frameOwner.terminals` (review of #35470, T5).
    @Test
    func aHeldKeyShowsEachPanesOwnGroundInEveryFrame() throws {
        let rig = Rig(Self.column(Self.pair), focused: "p1")
        defer { rig.close() }
        #expect(rig.misses().isEmpty, "SETUP: at rest a pane's ground does not cover it: \(rig.misses())")
        var found: [String] = []
        var frames = 0
        for press in 1...3 {
            #expect(PaneResize.press("p1", .right, model: rig.model, view: rig.root), "press \(press) moved nothing")
            rig.root.syncWithModel()
            rig.root.layoutSubtreeIfNeeded()
            found += rig.misses().map { "press \(press): \($0)" }
            for _ in 1...4 where rig.frame() {
                frames += 1
                found += rig.misses().map { "frame \(frames): \($0)" }
            }
        }
        while frames < 360, rig.frame() {
            frames += 1
            found += rig.misses().map { "frame \(frames): \($0)" }
        }
        rig.commit()
        found += rig.misses().map { "after the landing commit: \($0)" }
        #expect(frames > 12, "the presses did not spring (\(frames) frames)")
        #expect(found.isEmpty, "\(found.count) pane frames show no ground of their own (the shell shows there); first: \(found.prefix(3)), last: \(found.suffix(1))")
    }

    /// (c) Cmd-W on the middle of three split panes; (d) on the middle of three columns. At every tick the closed pane's
    /// place is covered by panes (the closing one shrinking on its neighbours' spring) beyond the gap it rests at.
    @Test(arguments: [false, true])
    func aCloseLeavesNoHoleWhereThePaneWas(columns: Bool) throws {
        let layout: ScreenLayout = columns
            ? .columns([LayoutColumn(id: "c0", width: 1.0 / 3, root: .leaf("p1")), LayoutColumn(id: "c1", width: 1.0 / 3, root: .leaf("p2")),
                        LayoutColumn(id: "c2", width: 1.0 / 3, root: .leaf("p3"))])
            : Self.column(.split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                 b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))
        let rig = Rig(layout, focused: "p2")
        defer { rig.close() }
        let closing = try #require(rig.root.context.hosts["p2"])
        let place = closing.convert(closing.bounds, to: nil)
        #expect(try rig.uncoveredWidth(of: place) < 1, "SETUP: p2's place is not covered at rest")
        _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        let first = try rig.uncoveredWidth(of: place)
        var holes: [(frame: Int, width: CGFloat)] = [(0, first)]
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            let width = try rig.uncoveredWidth(of: place)
            holes.append((frames, width))
        }
        rig.commit()
        let rest = try rig.uncoveredWidth(of: place)
        let open = holes.filter { $0.width > rest + 1 }
        let state = closing.isHidden ? "hidden" : "shown"
        let widest = String(format: "%.1f", open.map(\.width).max() ?? 0), resting = String(format: "%.1f", rest)
        let firstOpen = open.prefix(3).map { "frame \($0.frame): \(String(format: "%.1f", $0.width))" }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show a hole where p2 was (the shell shows there; its host is \(state)), resting gap \(resting) pt; widest \(widest) pt; first \(firstOpen)")
        let found = rig.misses()
        #expect(found.isEmpty, "after the close a pane shows no ground of its own: \(found)")
    }

    /// (e) Guard: a divider drag lays the panes out live; each terminal's ground follows its pane in every step.
    @Test func aDividerDragShowsEachPanesOwnGroundInEveryStep() throws {
        let rig = Rig(Self.column(Self.pair), focused: "p1")
        defer { rig.close() }
        let screen = try rig.screen
        let handle = try #require(screen.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        var found: [String] = []
        screen.handleDrag(kind: .split("x"), event: .began(start, []))
        for step in 1...30 {
            screen.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            rig.root.syncWithModel()
            _ = rig.frame()
            found += rig.misses().map { "step \(step): \($0)" }
        }
        screen.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - 240, y: start.y), []))
        rig.root.syncWithModel()
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            found += rig.misses().map { "release frame \(frames): \($0)" }
        }
        #expect(found.isEmpty, "\(found.count) drag frames show no pane ground: first \(found.prefix(3))")
    }
}
