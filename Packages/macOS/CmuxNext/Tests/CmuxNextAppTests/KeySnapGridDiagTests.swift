import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// RESIZE P0 14 diag (nomerge): what each terminal holds at each step of a Reduce Motion key press
/// (``ReduceMotionKeyResizeGridTests``), to prove why its surface keeps its old size after the first frame tick.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct KeySnapGridDiagTests {
    typealias Screen = ReduceMotionPaneCloseFrameTests.ThreePanes

    private func dump(_ step: String, _ screen: Screen, _ hosts: [PaneHostView], _ reports: UInt64) {
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        var line = "DIAGKS \(step) grids+\(TerminalSurfaceView.gridReports - reports) stats \(presenter.stats)"
        for (index, session) in screen.sessions.enumerated() {
            let view = session.surfaceView, own = view.frameOwnership, host = session.view
            line += "\n  p\(index + 1): pane \(hosts[index].frame.size) host \(host.frame.size) surface \(view.frame.size) layer \(view.layer?.bounds.size ?? .zero)"
            line += " grid \(String(describing: view.fittedGrid)) state \(view.hostFrame(present: false).rawValue)"
            line += " ahead \(String(describing: own.ahead)) pending \(String(describing: own.pendingAhead)) inFlight \(String(describing: own.inFlight))"
            line += " wanted \(String(describing: own.wanted?.size)) presenter \(presenter.debugState(of: view))"
            line += " aheadKey \(host.aheadOfKeyResize) dropsAtRest \(host.dropsAheadAtRest) follows \(host.surfaceFollowsArea)"
        }
        for (id, screenView) in screen.root.screenViews {
            line += "\n  screen \(id): snapWaits \(screenView.frameInput.snapWaitsForContent) presentationWaiting \(screenView.frameInput.presentationWaiting)"
        }
        print(line)
    }

    @Test func diagReduceMotionKeyPress() async throws {
        let screen = try await Screen()
        defer { screen.close() }
        let panes: [PaneID] = ["p1", "p2", "p3"]
        let hosts = try panes.map { try #require(screen.root.context.hosts[$0], "no host for \($0.rawValue)") }
        let reports = TerminalSurfaceView.gridReports
        dump("rest", screen, hosts, reports)
        try #require(PaneResize.press("p2", .right, model: screen.model, view: screen.root), "Ctrl-Shift-L on p2 moved nothing")
        dump("press (before commit)", screen, hosts, reports)
        await TerminalKeyResizeFrameTests.commit()
        dump("key turn commit", screen, hosts, reports)
        var waits = 0
        let start = ContinuousClock.now
        _ = await ReduceMotionPaneCloseFrameTests.commits(screen, seconds: 1) { screen in
            waits += 1
            if waits <= 4 { dump("wait \(waits)", screen, hosts, reports) }
            return screen.sessions.allSatisfy { session in
                let view = session.surfaceView, state = view.hostFrame(present: false)
                return view.frameOwnership.ahead == nil || state == GHOSTTY_HOST_FRAME_READY || state == GHOSTTY_HOST_FRAME_SHOWN
            }
        }
        print("DIAGKS wait ended after \(waits) checks, \(start.duration(to: .now))")
        dump("after wait", screen, hosts, reports)
        _ = screen.root.advanceFrame(1.0 / 120)
        dump("tick advanceFrame", screen, hosts, reports)
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
        dump("tick layout", screen, hosts, reports)
        await TerminalKeyResizeFrameTests.commit()
        dump("tick commit", screen, hosts, reports)
        for index in 1...4 {
            await TerminalKeyResizeFrameTests.commit()
            dump("extra commit \(index)", screen, hosts, reports)
        }
        for index in 1...4 {
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: a stepped frame's layout pass
            await TerminalKeyResizeFrameTests.commit()
            dump("extra tick \(index)", screen, hosts, reports)
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline { await TerminalKeyResizeFrameTests.commit() }
        dump("after 500 ms of commits", screen, hosts, reports)
    }
}
