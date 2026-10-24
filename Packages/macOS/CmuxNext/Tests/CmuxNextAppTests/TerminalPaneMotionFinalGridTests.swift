import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import Foundation
import Testing

/// Cmd-D and Cmd-W resize the program in the terminal at the start of the pane's spring, not after it
/// (Lawrence 2026-10-23: "trigger TUI resize much faster, even before animation starts or finishes
/// playing"). A real terminal surface sits in a pane; a split or a close sends its final grid to the PTY
/// owner in the key's turn, once, and the landing sends nothing more.
///
/// The IO's grid requests come through the session's ordered input stream. A focus report sent after
/// a step is a marker: once the IO has it, every request sent before it has arrived, so the test reads
/// what was sent by each point without waiting on a clock.
@MainActor @Suite(.serialized) struct TerminalPaneMotionFinalGridTests {
    final class Panes: LayoutPaneContentProvider {
        var views: [PaneID: NSView] = [:]
        func makeContentView(for pane: PaneID) -> NSView { views[pane] ?? NSView() }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let io = GridRecordingTerminalIO()
        let session: TerminalSession

        init(_ tree: SplitNode, terminal pane: PaneID, size: NSSize = NSSize(width: 1200, height: 800)) {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            provider.views[pane] = session.view
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: pane)
            model.splitSizingOverride = .even
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        func close() {
            io.finish()
            window.close()
        }

        var surface: TerminalSurfaceView { session.surfaceView }

        /// The grids the IO was asked for since the last call, up to now.
        func grids() async -> [TerminalGridSize] {
            surface.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }

        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// Steps 120 Hz frames until nothing moves (at most 2 s); the frame count.
        @discardableResult
        func settle() -> Int {
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                frames += 1
            }
            root.layoutSubtreeIfNeeded()
            return frames
        }

        /// The grid the surface fits at rest.
        var restGrid: TerminalGridSize? { surface.fittedGrid }
    }

    static let pair: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
    static let stack: SplitNode = .split("v", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))

    /// Cmd-D: the terminal that shrinks to make room sends its final grid in the key's turn.
    @Test(arguments: [Self.pair, Self.stack])
    func aSplitSendsTheShrinkingTerminalsFinalGridAtTheStartAndNothingAtTheLanding(split: SplitNode) async throws {
        let screen = Screen(.leaf("p1"), terminal: "p1")
        defer { screen.close() }
        try #require(screen.surface.surface != nil, "libghostty created no surface")
        _ = await screen.grids()
        let before = try #require(screen.restGrid)

        screen.show(split)
        let atStart = await screen.grids()
        let frames = screen.settle()
        let atLanding = await screen.grids()
        let final = try #require(screen.restGrid)

        #expect(frames > 3, "the split did not spring")
        #expect(final != before, "the split did not change the terminal's grid")
        #expect(atStart == [final], "the key's turn asked for \(atStart), not the final grid \(final)")
        #expect(atLanding.isEmpty, "the landing asked for \(atLanding) after the start")
    }

    /// Cmd-W: the terminal that grows into the closed pane's space sends its final grid in the key's turn.
    @Test(arguments: [Self.pair, Self.stack])
    func aCloseSendsTheGrowingTerminalsFinalGridAtTheStartAndNothingAtTheLanding(tree: SplitNode) async throws {
        let screen = Screen(tree, terminal: "p1")
        defer { screen.close() }
        try #require(screen.surface.surface != nil, "libghostty created no surface")
        _ = await screen.grids()
        let before = try #require(screen.restGrid)

        _ = try #require(screen.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        screen.root.syncWithModel()
        let atStart = await screen.grids()
        let frames = screen.settle()
        let atLanding = await screen.grids()
        let final = try #require(screen.restGrid)

        #expect(frames > 3, "the close did not spring")
        #expect(final != before, "the close did not change the terminal's grid")
        #expect(atStart == [final], "the key's turn asked for \(atStart), not the final grid \(final)")
        #expect(atLanding.isEmpty, "the landing asked for \(atLanding) after the start")
    }

    /// A pane that grows downward keeps its prompt in view: a shell whose cursor is on the last row (the
    /// owner pulls scrollback down as the grid grows) rides the bottom of the moving pane, not the top.
    @Test func aTerminalWithItsPromptAtTheBottomRidesTheBottomOfAPaneThatGrowsDown() async throws {
        let screen = Screen(Self.stack, terminal: "p1")
        defer { screen.close() }
        try #require(screen.surface.surface != nil, "libghostty created no surface")
        // A device attributes query after the prompt: its reply says the lines before it were parsed.
        screen.io.send(.output(Data((String(repeating: "line\r\n", count: 200) + "$ \u{1b}[c").utf8)))
        await screen.io.nextWrite()

        _ = try #require(screen.model.showPaneClose("p2"), "p2 did not close in the key's turn")
        screen.root.syncWithModel()
        var checked = 0
        for _ in 1...240 {
            let moving = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded()
            guard moving else { break }
            // The pane's clip: the view the layout puts the terminal's content in.
            let clip = try #require(screen.session.view.superview)
            let surface = screen.surface.convert(screen.surface.bounds, to: clip)
            let visible = clip.bounds
            if surface.height > visible.height + 1 {
                let cut = clip.isFlipped ? surface.maxY - visible.maxY : visible.minY - surface.minY
                #expect(abs(cut) < 1, "frame \(checked): \(cut) pt of the terminal's bottom is cut off")
                checked += 1
            }
        }
        #expect(checked > 3, "the held terminal was taller than its pane on \(checked) frames only")
    }
}

/// A ``TerminalIO`` that records the grids it is asked for, in order with the focus reports the test
/// sends as markers. It does not answer terminal queries, so the surface replies to them itself.
nonisolated final class GridRecordingTerminalIO: TerminalIO {
    enum Item: Sendable {
        case grid(TerminalGridSize)
        case marker
    }

    let events: AsyncStream<TerminalIOEvent>
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let items: AsyncStream<Item>
    private let itemSink: AsyncStream<Item>.Continuation
    private let writes: AsyncStream<Void>
    private let writeSink: AsyncStream<Void>.Continuation

    init() {
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        (items, itemSink) = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
        (writes, writeSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    }

    func send(_ event: TerminalIOEvent) { continuation.yield(event) }
    func finish() {
        continuation.finish()
        itemSink.finish()
        writeSink.finish()
    }

    func write(_ data: Data) async { writeSink.yield() }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        itemSink.yield(.grid(TerminalGridSize(columns: cols, rows: rows)))
    }
    func focusGained() async { itemSink.yield(.marker) }

    /// The grids asked for before the next marker.
    @MainActor func gridsUntilMarker() async -> [TerminalGridSize] {
        var grids: [TerminalGridSize] = []
        for await item in items {
            switch item {
            case .grid(let grid): grids.append(grid)
            case .marker: return grids
            }
        }
        return grids
    }

    /// Returns at the next write the surface makes (a query's reply).
    @MainActor func nextWrite() async {
        for await _ in writes { return }
    }
}
