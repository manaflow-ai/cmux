import AppKit
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Closing a pane's last tab (or the pane) and closing a window
/// (plans/cmux-next/close-animation/DESIGN.md). The pane leaves its window in the key's turn with
/// the even sizes the close leaves, so its neighbours spring into its space on one spring (the
/// split's) from the key's frame; the daemon's echoes change nothing on screen; their terminals
/// resize their PTYs once, at rest. A window fades out as a whole, then closes once. Reduce Motion
/// closes at once. Frames step at a fixed 120 Hz dt.
@MainActor
@Suite(.closesItsWindows)
struct PaneCloseMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    static let dt = 1.0 / 120
    /// The token's time scale (`ui.animationSpeed`), so budgets hold at any speed.
    static var scale: Double { Motion.panes.spring(.move).response / MotionSpring.move.base.response }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        var intents: [LayoutIntent] = []
        var holds: [Bool] = []

        init(_ layout: ScreenLayout, focused: PaneID? = nil, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s",
                                focusedPane: focused ?? layout.panes.first)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            // Pins the pane springs on (or off): the shared settings stay untouched.
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            model.intentHandler = { [weak self] in self?.intents.append($0) }
            root.onTerminalGridHold = { [weak self] in self?.holds.append($0) }
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        /// The daemon's tree, as the store's mirror shows it.
        func show(_ tree: SplitNode) {
            show(layout: .splits(tree))
        }

        func show(layout: ScreenLayout) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
            root.syncWithModel()
        }

        /// Cmd-W on `pane`'s last tab: the key's turn.
        func close(_ pane: PaneID) -> PendingPaneClose? {
            let close = model.showPaneClose(pane)
            root.syncWithModel()
            return close
        }

        func rect(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.rect }
        func target(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.targetRect }

        @discardableResult
        func step() -> Bool { root.advanceFrame(PaneCloseMotionTests.dt) }

        /// Steps until nothing moves (at most 2 s); the frame count.
        @discardableResult
        func settle() -> Int {
            for frame in 1...240 where !step() { return frame }
            return 240
        }

        var widthIntents: [(ColumnID, Double)] {
            intents.compactMap { intent in
                guard case let .setColumnWidth(column, _, width, _, .ended) = intent else { return nil }
                return (column, width)
            }
        }

        var ratioIntents: [(SplitID, Double)] {
            intents.compactMap { intent in
                guard case let .setSplitRatio(split, ratio, _, .ended) = intent else { return nil }
                return (split, ratio)
            }
        }

        func tearDown() { window.closeAfterTest() }
    }

    /// p1 | p2 | p3, even.
    static let row: SplitNode = .split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                       b: .split("r2", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
    /// `row` after the daemon closed p2 (its sibling p3 takes r2's place), before the close sizing.
    static let rowClosed: SplitNode = .split("r1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"), b: .leaf("p3"))
    /// `row` while p2 is empty (the daemon's echo of the tab close, before the pane goes).
    static let rowEmptied = row

    // MARK: One motion from the key's frame

    @Test func aLastTabCloseMovesEveryNeighbourFromTheKeysFirstFrame() throws {
        let screen = Screen(.splits(Self.row))
        defer { screen.tearDown() }
        let p1 = try #require(screen.rect("p1")), p3 = try #require(screen.rect("p3"))
        let close = try #require(screen.close("p2"), "a pane with a sibling did not close in the key's turn")
        #expect(close.successor == "p3")
        #expect(screen.model.screens.first?.layout.contains("p2") == false, "the closed pane is still shown")
        #expect(screen.model.screens.first?.layout.ratio(of: "r1") == 0.5, "the chain did not take its even sizes with the close")
        screen.step()
        let first1 = try #require(screen.rect("p1")), first3 = try #require(screen.rect("p3"))
        #expect(first1.width > p1.width + 1, "p1 did not grow in the key's first frame")
        #expect(first3.minX < p3.minX - 1, "p3 did not move in the key's first frame")
        screen.settle()
        let widths = try ["p1", "p3"].map { try #require(screen.rect($0)).width }
        #expect(abs(widths[0] - widths[1]) <= 1.5, "the chain did not end even: \(widths)")
        #expect(screen.intents.isEmpty, "a ratio intent went before the daemon closed the pane")
    }

    /// The daemon's echoes land mid-spring: the tab close (the pane still in its tree, empty), then
    /// the pane close with its old ratios. Nothing on screen changes course, and the close sizing
    /// goes to the daemon once its tree lost the pane.
    @Test func theDaemonsEchoesOfTheCloseChangeNothingOnScreen() throws {
        let screen = Screen(.splits(Self.row))
        defer { screen.tearDown() }
        _ = try #require(screen.close("p2"))
        for _ in 1...6 { screen.step() }
        let targets = try ["p1", "p3"].map { try #require(screen.target($0)) }
        screen.show(Self.rowEmptied)
        #expect(screen.rect("p2") == nil, "the tab close's echo showed the closed pane again")
        #expect(try ["p1", "p3"].map { try #require(screen.target($0)) } == targets)
        for _ in 1...6 { screen.step() }
        screen.show(Self.rowClosed)
        #expect(try ["p1", "p3"].map { try #require(screen.target($0)) } == targets, "the pane close's echo retargeted the panes")
        let sent = screen.ratioIntents
        #expect(sent.count == 1 && sent.first?.0 == "r1" && abs((sent.first?.1 ?? 0) - 0.5) < 1e-6, "sent \(sent)")
        #expect(!screen.model.isClosing("p2"))
    }

    @Test func aRefusedCloseBringsThePaneBackWithItsSizes() throws {
        let screen = Screen(.splits(Self.row))
        defer { screen.tearDown() }
        let before = try ["p1", "p2", "p3"].map { try #require(screen.rect($0)) }
        let close = try #require(screen.close("p2"))
        for _ in 1...4 { screen.step() }
        screen.model.cancelPaneClose(close)
        screen.root.syncWithModel()
        screen.settle()
        #expect(try ["p1", "p2", "p3"].map { try #require(screen.rect($0)) } == before, "the panes did not go back")
        #expect(screen.model.screens.first?.layout.ratio(of: "r1") == 1.0 / 3)
        #expect(screen.intents.isEmpty)
    }

    /// An accepted close yields to the next snapshot (asked after the close committed): a daemon
    /// that kept the pane shows it again instead of hiding it for good.
    @Test func aSettledCloseYieldsToTheNextSnapshot() throws {
        let screen = Screen(.splits(Self.row))
        defer { screen.tearDown() }
        let close = try #require(screen.close("p2"))
        screen.model.settlePaneClose(close)
        screen.show(Self.row)
        #expect(screen.model.screens.first?.layout.contains("p2") == true)
    }

    @Test func theFocusLeavesTheClosedPaneForThePaneTakingItsSpace() throws {
        let screen = Screen(.splits(Self.row), focused: "p2")
        defer { screen.tearDown() }
        _ = try #require(screen.close("p2"))
        #expect(screen.model.focusedPane == "p3")
    }

    /// The screen's last pane leaves with the daemon's tree.
    @Test func theScreensLastPaneLeavesWithTheDaemonsTree() {
        let lone = Screen(.splits(.leaf("p1")))
        defer { lone.tearDown() }
        #expect(lone.close("p1") == nil)
        let strip = Screen(.columns([LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
                                     LayoutColumn(id: "c2", width: 0.5, root: .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))]))
        defer { strip.tearDown() }
        #expect(strip.close("p2")?.successor == "p3", "a pane with a sibling in its column did not close in the key's turn")
    }

    // MARK: A column's only pane

    /// The chat docked left, then the strip's two columns sharing the viewport.
    static let strip: [LayoutColumn] = [
        LayoutColumn(id: "c0", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .left, role: .agentChat)),
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
    ]

    /// Leo 2026-10-25: "we should never block shit on the tab animation". The right column's only
    /// pane stayed, empty, until the daemon's tree without it came back, while its strip played the
    /// tab's close; it leaves with its column in the key's turn now: the focus goes left, the column
    /// left takes its final width in that turn, and it moves from the key's first frame.
    @Test func aColumnsOnlyPaneLeavesWithItsColumnInTheKeysTurn() throws {
        let screen = Screen(.columns(Self.strip), focused: "p2")
        defer { screen.tearDown() }
        screen.model.newColumnWidthModeOverride = .fitScreen
        let start = try #require(screen.rect("p1"))
        let close = try #require(screen.close("p2"), "the right column's only pane waited for the daemon's tree")
        #expect(close.successor == "p1")
        #expect(screen.model.focusedPane == "p1", "the focus stayed on the closed pane")
        let shown = try #require(screen.model.screens.first?.layout)
        #expect(!shown.contains("p2"), "the closed pane is still shown")
        #expect(shown.columns.first { $0.id == "c1" }?.width == 1, "the column left did not take the viewport in the key's turn")
        #expect(screen.rect("p2") == nil, "the closed pane's host stayed on screen")
        let target = try #require(screen.target("p1"))
        #expect(target.width > start.width + 1, "p1's target in the key's turn is not wider")
        screen.step()
        #expect(try #require(screen.rect("p1")).width > start.width + 1, "p1 did not grow in the key's first frame")
        #expect(screen.target("p1") == target)
        screen.settle()
        #expect(screen.rect("p1") == target, "the key's turn did not set p1's final frame")
        #expect(screen.intents.isEmpty, "an intent went before the daemon closed the pane")
    }

    /// The daemon's echoes (the emptied column, then the tree without it) change nothing on screen,
    /// and the width the close leaves goes to the daemon once, after its tree lost the column.
    @Test func theDaemonsEchoesOfAColumnCloseChangeNothingOnScreen() throws {
        let screen = Screen(.columns(Self.strip), focused: "p2")
        defer { screen.tearDown() }
        screen.model.newColumnWidthModeOverride = .fitScreen
        _ = try #require(screen.close("p2"))
        for _ in 1...6 { screen.step() }
        let targets = try ["chat", "p1"].map { try #require(screen.target($0)) }
        screen.show(layout: .columns(Self.strip))
        #expect(screen.rect("p2") == nil, "the tab close's echo showed the closed pane again")
        #expect(try ["chat", "p1"].map { try #require(screen.target($0)) } == targets)
        screen.show(layout: .columns(Array(Self.strip.prefix(2))))
        #expect(try ["chat", "p1"].map { try #require(screen.target($0)) } == targets, "the column close's echo retargeted the panes")
        let sent = screen.widthIntents
        #expect(sent.count == 1 && sent.first?.0 == "c1" && sent.first?.1 == 1, "sent \(sent)")
        #expect(!screen.model.isClosing("p2"))
    }

    @Test func aRefusedColumnCloseBringsTheColumnAndItsWidthsBack() throws {
        let screen = Screen(.columns(Self.strip), focused: "p2")
        defer { screen.tearDown() }
        screen.model.newColumnWidthModeOverride = .fitScreen
        let before = screen.model.screens.first?.layout
        let close = try #require(screen.close("p2"))
        for _ in 1...4 { screen.step() }
        screen.model.cancelPaneClose(close)
        screen.root.syncWithModel()
        #expect(screen.model.screens.first?.layout == before)
        screen.settle()
        #expect(screen.rect("p2") != nil, "the refused column did not come back")
        #expect(screen.intents.isEmpty)
    }

    /// Home's pinned dock with a column beside it (Cmd-D in Home): the dock stays alone, docked, at
    /// its width, as cmux-tui keeps it (`pinned-dock-alone-v1`).
    @Test func homesColumnBesideThePinnedDockLeavesInTheKeysTurn() throws {
        let dock = LayoutColumn(id: "c0", width: 0.35, root: .leaf("home"), dock: DockColumn(edge: .left, isPinned: true))
        let screen = Screen(.columns([dock, LayoutColumn(id: "c1", width: 0.65, root: .leaf("p1"))]), focused: "p1")
        defer { screen.tearDown() }
        let close = try #require(screen.close("p1"))
        #expect(close.successor == "home")
        #expect(screen.model.focusedPane == "home")
        #expect(screen.model.screens.first?.layout == .columns([dock]))
        #expect(screen.rect("p1") == nil)
    }

    /// The last scrolling column left is the screen's tree again, as the daemon shows it; a dock
    /// with no scrolling column beside it scrolls again.
    @Test func theColumnsLeftTakeTheDaemonsShapeInTheKeysTurn() throws {
        let tree: SplitNode = .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p3"))
        let pair = Screen(.columns([LayoutColumn(id: "c1", width: 0.5, root: tree), LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2"))]),
                          focused: "p2")
        defer { pair.tearDown() }
        #expect(pair.close("p2")?.successor == "p1")
        #expect(pair.model.screens.first?.layout == .splits(tree))
        let docked = Screen(.columns(Array(Self.strip.dropLast()) + [LayoutColumn(id: "c3", width: 0.3, root: .leaf("p3"), dock: DockColumn(edge: .right))]))
        defer { docked.tearDown() }
        _ = try #require(docked.close("p1"))
        let columns = docked.model.screens.first?.layout.columns ?? []
        #expect(columns.map(\.id) == ["c0", "c3"] && columns.allSatisfy { $0.dock == nil }, "\(columns)")
    }

    /// Click to final layout, in frames of the same harness, with the daemon's tree 100 ms after the
    /// key: the right column's close sets its final layout in the key's turn (frame 0), not at the echo.
    @Test func aColumnCloseSetsItsFinalLayoutInTheKeysTurn() throws {
        let screen = Screen(.columns(Self.strip), focused: "p2")
        defer { screen.tearDown() }
        screen.model.newColumnWidthModeOverride = .fitScreen
        _ = screen.close("p2")
        let echo = Int((0.1 / Self.dt).rounded())
        var targets: [CGRect?] = [screen.target("p1")], focus: [PaneID?] = [screen.model.focusedPane], rest = 0
        for frame in 1...240 {
            if frame == echo { screen.show(layout: .columns(Array(Self.strip.prefix(2)))) }
            let moving = screen.step()
            targets.append(screen.target("p1"))
            focus.append(screen.model.focusedPane)
            if !moving, frame > echo { rest = frame; break }
        }
        let final = targets.last ?? nil
        let finalAt = targets.firstIndex { $0 == final } ?? -1, focusAt = focus.firstIndex { $0 == "p1" } ?? -1
        print("column close: final target at frame \(finalAt), focus at frame \(focusAt), at rest at frame \(rest) (120 Hz, echo at \(echo))")
        #expect(finalAt == 0, "the final layout waited \(finalAt) frames")
        #expect(focusAt == 0, "the focus waited \(focusAt) frames")
    }

    // MARK: The spring

    /// A close is a split run backwards: the same spring (`split`, 0.23 s, damping 0.95), about two
    /// fifths of the way at 50 ms, no visible overshoot, exactly at rest within 0.75 s.
    @Test(arguments: [SplitAxis.horizontal, .vertical])
    func aCloseRunsOnTheSplitSpringWithoutOvershootAndLandsExactly(axis: SplitAxis) throws {
        let screen = Screen(.splits(.split("v", axis: axis, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))
        defer { screen.tearDown() }
        let extent: (CGRect) -> CGFloat = { axis == .horizontal ? $0.width : $0.height }
        let start = extent(try #require(screen.rect("p1")))
        _ = try #require(screen.close("p2"))
        let target = try #require(screen.target("p1"))
        var sizes: [CGFloat] = [], rest: Int?
        for frame in 1...180 {
            let moving = screen.step()
            sizes.append(extent(try #require(screen.rect("p1"))))
            if rest == nil, !moving { rest = frame }
        }
        let travel = extent(target) - start
        let early = (sizes[Int((0.05 * Self.scale / Self.dt).rounded()) - 1] - start) / travel
        #expect(early > 0.3 && early < 0.55, "at 50 ms the close is at \(early) of its travel")
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $1 >= $0 - 0.1 }, "the growing pane shrank on its way")
        #expect(sizes.allSatisfy { $0 <= extent(target) + 0.25 }, "the growing pane overshot: \(sizes.max() ?? 0) > \(extent(target))")
        #expect(screen.rect("p1") == target)
        #expect((rest ?? .max) <= Int((0.75 * Self.scale / Self.dt).rounded(.up)), "at rest at frame \(rest.map(String.init) ?? "never")")
    }

    // MARK: Terminals

    /// The neighbours' terminals resize at the start of the close (Lawrence 2026-10-23): no grid is held while
    /// they spring into the closed pane's space.
    @Test func aCloseHoldsNoTerminalGrid() throws {
        let screen = Screen(.splits(Self.row))
        defer { screen.tearDown() }
        _ = try #require(screen.close("p2"))
        for _ in 1...240 {
            #expect(!screen.root.holdsTerminalGrids, "the close holds the grids")
            if !screen.step() { break }
        }
        #expect(screen.holds.isEmpty, "hold changes: \(screen.holds)")
    }

    @Test func reduceMotionClosesInOneFrameAndHoldsNoGrid() throws {
        let screen = Screen(.splits(Self.row), reduceMotion: true)
        defer { screen.tearDown() }
        _ = try #require(screen.close("p2"))
        for pane: PaneID in ["p1", "p3"] {
            #expect(screen.rect(pane) == screen.target(pane), "\(pane) animates under Reduce Motion")
        }
        #expect(!screen.root.holdsTerminalGrids)
        #expect(screen.holds.isEmpty)
        #expect(!screen.step())
    }

    // MARK: Windows

    /// A window the person closes fades out as a whole from the key's frame, takes no click while
    /// it fades, and closes once at the end of the fade; it shows whole if it opens again.
    @Test func aClosedWindowFadesOutAndClosesOnceAtTheEnd() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        var closes = 0
        let motion = WindowCloseMotion(window: window) { closes += 1 }
        motion.start(handingKeysTo: nil, driven: false)
        #expect(window.ignoresMouseEvents, "a fading window takes clicks")
        var alphas: [CGFloat] = []
        var frames = 0
        while motion.step(Self.dt), frames < 240 {
            frames += 1
            alphas.append(window.alphaValue)
            #expect(closes == 0, "the window closed before its fade ended")
        }
        #expect((alphas.first ?? 1) < 1, "the fade did not start in the first frame")
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $1 <= $0 }, "the window came back up while fading")
        #expect(frames <= Int((0.35 * Self.scale / Self.dt).rounded(.up)), "the fade took \(frames) frames")
        #expect(closes == 1)
        motion.finish()
        #expect(closes == 1, "a second close closed the window twice")
        #expect(window.alphaValue == 1 && !window.ignoresMouseEvents, "a closed window does not show whole again")
    }

    /// The window's child windows (Chromium pages, the overlay panel above them, a popup's own
    /// child) fade with it: AppKit does not pass a parent's alpha to its children, so a page stayed
    /// opaque on the fading window and went only when it closed. A child keeps its own alpha as
    /// the top of its fade and gets it back when the window closes.
    @Test func aClosedWindowFadesItsChildWindowsWithIt() {
        func make(_ alpha: CGFloat = 1) -> NSWindow {
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
            child.isReleasedWhenClosed = false
            child.alphaValue = alpha
            return child
        }
        let window = make()
        let page = make()
        let panel = make(0.5)
        let nested = make()
        defer { [window, page, panel, nested].forEach { $0.closeAfterTest() } }
        window.addChildWindow(page, ordered: .above)
        window.addChildWindow(panel, ordered: .above)
        page.addChildWindow(nested, ordered: .above)
        defer { [nested, panel, page].forEach { $0.parent?.removeChildWindow($0) } }
        #expect(window.childWindows?.count == 2 && page.childWindows?.count == 1, "the child windows were not added")
        let motion = WindowCloseMotion(window: window) {}
        motion.start(handingKeysTo: nil, driven: false)
        var frames = 0
        while motion.step(Self.dt), frames < 240 {
            frames += 1
            let a = window.alphaValue
            #expect(abs(page.alphaValue - a) < 0.001, "a page window stayed at \(page.alphaValue) while its window was at \(a)")
            #expect(abs(nested.alphaValue - a) < 0.001, "a child of a child window did not fade")
            #expect(abs(panel.alphaValue - 0.5 * a) < 0.001, "a child window lost its own alpha in the fade")
        }
        #expect(frames > 0)
        #expect(page.alphaValue == 1 && nested.alphaValue == 1 && panel.alphaValue == 0.5,
                "a child window does not get its alpha back when the window closes")
    }

    /// A child whose owner sets its alpha during the fade (a panel's own fade) keeps the owner's
    /// alpha, and a child that moves under another window (a palette follows the key window) is
    /// whole again at once: the fade dims only what is still the closing window's.
    @Test func aWindowFadeLeavesAChildItsOwnerOrAnotherWindowTook() {
        func make() -> NSWindow {
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless],
                                 backing: .buffered, defer: true)
            child.isReleasedWhenClosed = false
            return child
        }
        let window = make()
        let other = make()
        let panel = make()
        let palette = make()
        defer { [window, other, panel, palette].forEach { $0.closeAfterTest() } }
        window.addChildWindow(panel, ordered: .above)
        window.addChildWindow(palette, ordered: .above)
        defer { [panel, palette].forEach { $0.parent?.removeChildWindow($0) } }
        let motion = WindowCloseMotion(window: window) {}
        motion.start(handingKeysTo: nil, driven: false)
        for _ in 0..<3 { motion.step(Self.dt) }
        #expect(panel.alphaValue < 1 && palette.alphaValue < 1, "the children did not start to fade")
        panel.alphaValue = 0.3
        window.removeChildWindow(palette)
        other.addChildWindow(palette, ordered: .above)
        var frames = 0
        while motion.step(Self.dt), frames < 240 {
            frames += 1
            #expect(panel.alphaValue == 0.3, "the fade overwrote the alpha a child's owner set")
            #expect(palette.alphaValue == 1, "a child that moved to another window stayed faded")
        }
        #expect(frames > 0)
        #expect(panel.alphaValue == 0.3 && palette.alphaValue == 1, "the fade's end changed a child it let go of")
    }

    @Test func aWindowCloseUnderReduceMotionDoesNotFade() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        #expect(!WindowCloseMotion.fades(window, animates: false))
    }
}
