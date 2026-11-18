import AppKit
import CmuxNextBridge
// Only the grid size: CmuxNextDaemon has its own PaneID and SplitID (the daemon's handles).
import CmuxNextTestSupport
import struct CmuxNextDaemon.CellSize
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Cmd-D and Cmd-Shift-D with even sizing (plans/cmux-next/split-spring-animation/DESIGN.md): the split
/// and the even sizing of its chain are one layout change, in the key's turn, so every pane and divider
/// of the chain is at its place in the split's one frame (`PaneLayoutCommitTests`); the daemon's reply,
/// ~100 ms later, changes nothing on screen. A split has no spring: these tests keep the rules of the
/// sizing (when it shows, when it goes to the daemon, a refused split) and of the row's tiling. Frames
/// step at a fixed 120 Hz dt, so every assertion is about frame N, not wall time.
@MainActor
@Suite(.closesItsWindows)
struct SplitSpringMotionTests {
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

        init(_ tree: SplitNode, reduceMotion: Bool = false) {
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
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

        /// Shows `tree` (the store's provisional split, or its undo) as the daemon mirror would.
        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// The spring's rect of `pane` now (unrounded).
        func rect(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.rect }
        /// Where `pane` rests.
        func target(_ pane: PaneID) -> CGRect? { screen?.paneFrames[pane]?.targetRect }

        @discardableResult
        func step() -> Bool { root.advanceFrame(SplitSpringMotionTests.dt) }
    }

    static let pair: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    /// `pair` after Cmd-D on p2, as the store's provisional split shows it (the new split at 0.5).
    static let pairSplit: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"),
                                             b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))

    /// The chain of `pairSplit`, left to right.
    static let chain: [PaneID] = ["p1", "p2", "p3"]

    /// Cmd-D on p2 of p1 | p2 with even sizing: the key's turn shows the split and the sizing.
    static func splitPair(_ screen: Screen) -> PendingSplitSizing {
        let changes = screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal)
        let sizing = screen.model.showSplitSizing(changes)
        screen.show(pairSplit)
        return sizing
    }

    // MARK: One motion

    @Test func anEvenSplitMovesEveryPaneOfItsChainFromTheKeysFirstFrame() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        let before = try #require(screen.rect("p1"))
        _ = Self.splitPair(screen)
        screen.step()
        // Frame 1: the pane beside the split one gives up its room too, not after the reply.
        let first = try #require(screen.rect("p1"))
        #expect(first.width < before.width - 1, "p1 did not move in the key's first frame: two motions, not one")
        for _ in 1...120 { screen.step() }
        let widths = try Self.chain.map { try #require(screen.rect($0)).width }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.5, "the chain did not end even: \(widths)")
    }

    /// The user's repro: the daemon's reply lands ~100 ms (12 frames) into the spring and sends
    /// the sizing. Nothing on screen may change course then: no new target, no second motion.
    @Test func theRepliesSizingLandingMidSpringChangesNothingOnScreen() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        let sizing = Self.splitPair(screen)
        var rows: [String] = []
        func record(_ frame: Int) {
            let cells = Self.chain.map { pane in screen.rect(pane).map { String(format: "%6.1f", $0.width) } ?? "     -" }
            rows.append("\(frame)\t" + cells.joined(separator: "\t"))
        }
        record(0)
        for frame in 1...12 {
            screen.step()
            record(frame)
        }
        let targets = try Self.chain.map { try #require(screen.target($0)) }
        screen.model.commitSplitSizing(sizing)
        screen.root.syncWithModel()
        let after = try Self.chain.map { try #require(screen.target($0)) }
        var p1: [CGFloat] = []
        for frame in 13...90 {
            screen.step()
            record(frame)
            if let width = screen.rect("p1")?.width { p1.append(width) }
        }
        print("split-spring frames (120 Hz; widths p1 p2 p3; reply at frame 12):\n" + rows.joined(separator: "\n"))
        #expect(after == targets, "the reply's sizing retargeted the panes mid-spring: a second motion")
        // Never growing back (0.1 pt: the split spring's sub-pixel tail may cross its target once).
        #expect(zip(p1, p1.dropFirst()).allSatisfy { $1 <= $0 + 0.1 }, "p1 reversed after the reply")
    }

    @Test func theSizingGoesToTheDaemonOnlyOnceTheSplitLanded() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        let sizing = Self.splitPair(screen)
        #expect(screen.intents.isEmpty, "a ratio intent went before the daemon made the split")
        screen.model.commitSplitSizing(sizing)
        let sent = screen.intents.compactMap { intent -> (SplitID, Double)? in
            guard case let .setSplitRatio(split, ratio, _, .ended) = intent else { return nil }
            return (split, ratio)
        }
        #expect(sent.count == 1 && sent.first?.0 == "r" && abs((sent.first?.1 ?? 0) - 1.0 / 3) < 1e-6, "sent \(sent)")
    }

    @Test func aRefusedSplitTakesItsSizingBack() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        let half = try #require(screen.target("p1"))
        let sizing = Self.splitPair(screen)
        for _ in 1...4 { screen.step() }
        // The store undoes the provisional split; the handler cancels the sizing in the same turn.
        screen.model.cancelSplitSizing(sizing)
        screen.show(Self.pair)
        for _ in 1...120 { screen.step() }
        #expect(screen.rect("p1") == half, "p1 did not go back to its half")
        #expect(screen.model.screens.first?.layout.ratio(of: "r") == 0.5)
        #expect(screen.intents.isEmpty)
    }

    // MARK: The row

    /// Every frame, the panes of the chain tile the row: no gap opens, nothing overlaps, the left
    /// edge never moves and the right one never leaves a hole (the panes and dividers fill the
    /// container).
    @Test func everyFrameOfAnEvenSplitTilesTheRow() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        _ = Self.splitPair(screen)
        let order = Self.chain
        let targets = try order.map { try #require(screen.target($0)) }
        let gaps = zip(targets, targets.dropFirst()).map { $1.minX - $0.maxX }
        for frame in 1...120 {
            screen.step()
            let rects = try order.map { try #require(screen.rect($0)) }
            // The left edge stays; the right one never leaves a hole.
            #expect(abs(rects[0].minX - targets[0].minX) < 0.01 && rects[2].maxX >= targets[2].maxX - 0.01,
                    "frame \(frame): an outer edge moved in")
            for (index, gap) in gaps.enumerated() {
                #expect(abs(rects[index + 1].minX - rects[index].maxX - gap) < 0.01, "frame \(frame): the gap after \(order[index]) changed")
            }
            #expect(rects == targets, "frame \(frame): a pane of the chain is not at its place: \(rects)")
        }
    }

    @Test func reduceMotionShowsTheEvenSplitInOneFrame() throws {
        let screen = Screen(Self.pair, reduceMotion: true)
        defer { screen.window.closeAfterTest() }
        _ = Self.splitPair(screen)
        for pane in Self.chain {
            #expect(screen.rect(pane) == screen.target(pane), "\(pane) animates under Reduce Motion")
        }
        let widths = try Self.chain.map { try #require(screen.rect($0)).width }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.5, "not even in the key's frame: \(widths)")
        #expect(!screen.step())
    }

    // MARK: Rapid splits (Lawrence 2026-10-20)

    /// Lawrence 2026-10-20: "when I do Command-D multiple times, the animation is not perfectly
    /// fluid and smooth ... we have to resize all of them at the same time". A row of `count`
    /// panes, p1 to p`count`, as the store shows it after Cmd-D on the last pane each time (each
    /// new split at 0.5 under the ratios the model shows).
    static func chainTree(_ count: Int, model: LayoutModel) -> SplitNode {
        func node(_ index: Int) -> SplitNode {
            guard index < count else { return .leaf(PaneID("p\(index)")) }
            let id = SplitID("c\(index)")
            let ratio = model.screens.first?.layout.ratio(of: id) ?? 0.5
            return .split(id, axis: .horizontal, ratio: ratio, a: .leaf(PaneID("p\(index)")), b: node(index + 1))
        }
        return node(1)
    }

    /// Cmd-D on the last pane of a row of `count`: the key's turn (the sizing, then the split).
    static func splitLast(_ screen: Screen, count: Int) {
        let changes = screen.model.splitSizingChanges(splitting: PaneID("p\(count)"), axis: .horizontal)
        _ = screen.model.showSplitSizing(changes)
        screen.show(chainTree(count + 1, model: screen.model))
    }

    /// A split's terminals resize with the split: the layout holds no grid for it.
    @Test func aSplitHoldsNoTerminalGrid() throws {
        let screen = Screen(Self.pair)
        defer { screen.window.closeAfterTest() }
        _ = Self.splitPair(screen)
        for _ in 1...240 {
            #expect(!screen.root.holdsTerminalGrids, "the split holds the grids")
            if !screen.step() { break }
        }
        #expect(screen.holds.isEmpty, "hold changes: \(screen.holds)")
    }

    /// Five Cmd-D presses 100 ms apart (a person pressing as fast as they can): every frame tiles the row, no
    /// grid is held, the row is even after the last press with nothing left moving, and no frame takes the
    /// main thread past a 120 Hz frame (8.3 ms).
    @Test func fiveRapidSplitsTileTheRowInEachFrameAndEndEven() throws {
        let screen = Screen(.leaf("p1"))
        defer { screen.window.closeAfterTest() }
        let pressEvery = Int((0.1 / Self.dt).rounded())
        let clock = ContinuousClock()
        var slowest = Duration.zero, frames = 0, lastPress = 0
        for press in 1...5 {
            let took = clock.measure { Self.splitLast(screen, count: press) }
            slowest = max(slowest, took)
            #expect(!screen.root.holdsTerminalGrids, "press \(press): the grids are held")
            lastPress = frames
            for _ in 0..<(press == 5 ? 240 : pressEvery) {
                var moving = false
                let took = clock.measure { moving = screen.step() }
                slowest = max(slowest, took)
                frames += 1
                let panes = (1...(press + 1)).map { PaneID("p\($0)") }
                let rects = try panes.map { try #require(screen.rect($0)) }
                // The row tiles: each pane starts one constant gap after the one before it.
                let gaps = zip(rects, rects.dropFirst()).map { $1.minX - $0.maxX }
                #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) < 0.01, "frame \(frames): the gaps differ \(gaps)")
                if !moving { break }
            }
        }
        let settled = frames - lastPress
        #expect(!screen.root.holdsTerminalGrids, "the grids are still held at rest")
        #expect(screen.holds.isEmpty, "a grid hold changed during the burst: \(screen.holds)")
        let widths = try (1...6).map { try #require(screen.rect(PaneID("p\($0)"))).width }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.5, "not even after five splits: \(widths)")
        #expect(settled <= Int((0.75 * Self.scale / Self.dt).rounded(.up)), "at rest \(settled) frames after the last press")
        print("rapid-split: \(frames) frames, slowest \(slowest), settled \(settled) frames after the 5th press")
        #expect(slowest < .microseconds(8333), "a frame of five rapid splits took \(slowest)")
    }

    // MARK: Cost

    /// No frame of a split in a 3 x 3 grid takes the main thread for a display frame.
    @Test func noFrameOfASplitHitchesTheMainThread() throws {
        func row(_ id: String, _ panes: [PaneID]) -> SplitNode {
            .split(SplitID("\(id)1"), axis: .horizontal, ratio: 1.0 / 3, a: .leaf(panes[0]),
                   b: .split(SplitID("\(id)2"), axis: .horizontal, ratio: 0.5, a: .leaf(panes[1]), b: .leaf(panes[2])))
        }
        func grid(_ middle: SplitNode) -> SplitNode {
            .split("g1", axis: .vertical, ratio: 1.0 / 3, a: row("a", ["p1", "p2", "p3"]),
                   b: .split("g2", axis: .vertical, ratio: 0.5, a: middle, b: row("c", ["p7", "p8", "p9"])))
        }
        let screen = Screen(grid(row("b", ["p4", "p5", "p6"])))
        defer { screen.window.closeAfterTest() }
        let split = SplitNode.split("b1", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p4"),
                                    b: .split("b2", axis: .horizontal, ratio: 0.5,
                                              a: .split("b3", axis: .horizontal, ratio: 0.5, a: .leaf("p5"), b: .leaf("p10")),
                                              b: .leaf("p6")))
        _ = screen.model.showSplitSizing(screen.model.splitSizingChanges(splitting: "p5", axis: .horizontal))
        let clock = ContinuousClock()
        var slowest = Duration.zero
        let shown = clock.measure { screen.show(grid(split)) }
        for _ in 1...90 {
            let took = clock.measure { screen.step() }
            slowest = max(slowest, took)
        }
        #expect(shown < .milliseconds(16), "the split's first layout took \(shown)")
        #expect(slowest < .milliseconds(16), "a frame of the split took \(slowest)")
    }

    /// While a pane's size changes on every frame (a keyboard resize, a drag), a terminal's grid changes
    /// every frame; its PTY gets at most one grid per echo (`ResizeCoordinator`), and the last one is the
    /// size it rests at.
    @Test func aTerminalWhoseGridChangesEachFrameResizesItsPTYAtMostOncePerEcho() {
        final class Terminal: ResizeTarget {
            var applied: [CellSize] = []
            var echoIn = 0
            var awaitsEcho: Bool { echoIn > 0 }
            func applySettled(_ size: CellSize) {
                applied.append(size)
                echoIn = 3
            }
        }
        let coordinator = ResizeCoordinator()
        let terminal = Terminal()
        let frames = 45
        for frame in 0..<frames {
            coordinator.submit(terminal, size: CellSize(cols: 160 - frame, rows: 48))
            _ = coordinator.tick()
            if terminal.echoIn > 0 { terminal.echoIn -= 1 }
        }
        for _ in 0..<10 {
            _ = coordinator.tick()
            if terminal.echoIn > 0 { terminal.echoIn -= 1 }
        }
        #expect(terminal.applied.count <= frames / 3 + 1, "\(terminal.applied.count) PTY resizes in \(frames) frames")
        #expect(terminal.applied.last == CellSize(cols: 160 - frames + 1, rows: 48))
    }
}
