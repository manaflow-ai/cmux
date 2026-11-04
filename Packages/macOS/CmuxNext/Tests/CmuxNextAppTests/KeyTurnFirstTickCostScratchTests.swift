import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextSignposts
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// SCRATCH (never lands; branch fix/frame-owner-s1b-tick-cost-nomerge): the main-thread time of a column key's own turn
/// and of its first frame tick, each up to the end of its Core Animation commit, with two real terminals that hold 400
/// lines, x1 speed. Run at #34380's merge 0eb02fe3b43 and at its parent fbf7e36e93d: #34380 moved the terminals' resize
/// (announceRest -> holdSurface -> ghostty_surface_set_size, on main) from the key's turn into the first tick.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyTurnFirstTickCostScratchTests {
    final class Panes: LayoutPaneContentProvider {
        let reveal: LaunchReveal = {
            let reveal = LaunchReveal()
            reveal.markAllReady()
            return reveal
        }()
        var sessions: [PaneID: (session: TerminalSession, io: ScriptedTerminalIO)] = [:]

        func makeContentView(for pane: PaneID) -> NSView {
            let io = ScriptedTerminalIO()
            let session = TerminalSession(io: io)
            let view = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("terminal"), title: "zsh")]), reveal: reveal)
            view.show(session.view)
            sessions[pane] = (session, io)
            return view
        }
    }

    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Returns after the next Core Animation commit of the main run loop.
    static func commit() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CommitBoundary().after { _ in done.resume() }
        }
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func line(_ name: String, _ values: [Double]) -> String {
        let sorted = values.sorted()
        func at(_ p: Double) -> String {
            guard !sorted.isEmpty else { return "-" }
            return String(format: "%.3f", sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))])
        }
        return "S1B-TICK-COST \(name) n=\(values.count) p50=\(at(0.5))ms p95=\(at(0.95))ms max=\(at(1))ms"
    }

    @Test(.enabled("terminals draw only in a window on screen") { await Self.hasDisplay() })
    func keyTurnAndFirstTickCost() async throws {
        _ = NSApplication.shared
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        model.followsDesignMetrics = false
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        defer {
            for (_, entry) in provider.sessions { entry.session.close(); entry.io.finish() }
            window.close()
        }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        let text = Array(repeating: String(repeating: "y", count: 60), count: 400).joined(separator: "\r\n")
        for (_, entry) in provider.sessions { entry.io.send(.output(Data(text.utf8))) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, provider.sessions.values.contains(where: { $0.session.surfaceView.presentedFrame == nil }) {
            await Self.commit()
        }
        try #require(!provider.sessions.values.contains { $0.session.surfaceView.presentedFrame == nil }, "a terminal never drew")

        var keyTurns: [Double] = [], firstTicks: [Double] = []
        for press in 0..<22 {
            // The key's own turn, up to its commit.
            let pressed = ContinuousClock.now
            #expect(PaneResize.press("p2", press.isMultiple(of: 2) ? .left : .right, model: model, view: root))
            await Self.commit()
            let keyTurn = Self.ms(pressed.duration(to: .now))
            // The first tick, in its own turn, up to its commit.
            let ticked = ContinuousClock.now
            var moving = root.advanceFrame(1.0 / 120)
            root.layoutSubtreeIfNeeded()
            await Self.commit()
            let firstTick = Self.ms(ticked.duration(to: .now))
            // The rest of the spring and the landing's release, then a few commits for the renderers.
            var frames = 1
            while moving, frames < 240 {
                moving = root.advanceFrame(1.0 / 120)
                root.layoutSubtreeIfNeeded()
                frames += 1
            }
            let work = afterCommit
            afterCommit.removeAll()
            for item in work { item() }
            root.layoutSubtreeIfNeeded()
            for _ in 0..<6 { await Self.commit() }
            // Two warm-up presses.
            if press >= 2 {
                keyTurns.append(keyTurn)
                firstTicks.append(firstTick)
            }
        }
        print(Self.line("key-turn", keyTurns))
        print(Self.line("first-tick", firstTicks))
        print(Self.line("sum", zip(keyTurns, firstTicks).map { $0 + $1 }))
        print("S1B-TICK-COST raw key-turn \(keyTurns.map { String(format: "%.2f", $0) })")
        print("S1B-TICK-COST raw first-tick \(firstTicks.map { String(format: "%.2f", $0) })")
    }
}
