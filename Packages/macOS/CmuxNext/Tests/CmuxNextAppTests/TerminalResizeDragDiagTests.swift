import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// DIAG (RESIZE P0 14, nomerge): per divider-drag move, each terminal's PTY grids, the ring sends in order, and what the
/// presenter saw (state per pass, holds, bound presents). Prints only; asserts nothing.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)),
                  .enabled(if: ["CMUX_TEST_REQUIRE_GUI", "CMUX_CI_DISPLAY_ROUTED"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct TerminalResizeDragDiagTests {
    static func name(_ state: ghostty_host_frame_e) -> String {
        switch state {
        case GHOSTTY_HOST_FRAME_READY: "R"
        case GHOSTTY_HOST_FRAME_READY_PROGRAM: "P"
        case GHOSTTY_HOST_FRAME_PENDING: "pend"
        case GHOSTTY_HOST_FRAME_HELD: "held"
        case GHOSTTY_HOST_FRAME_SHOWN: "shown"
        case GHOSTTY_HOST_FRAME_PRESENTED: "pres"
        case GHOSTTY_HOST_FRAME_NONE: "none"
        case GHOSTTY_HOST_FRAME_HIDDEN: "hid"
        default: "?\(state.rawValue)"
        }
    }

    static func line(_ screen: TerminalKeyResizeFrameTests.PaneScreen, _ presenter: TerminalFramePresenter) -> String {
        screen.sessions.enumerated().map { index, session in
            let v = session.surfaceView
            let grids = screen.ios[index].resizes.suffix(3).map { "\($0.columns)x\($0.rows)" }
            return "p\(index + 1)[layer \(TerminalKeyResizeFrameTests.text(v.layer?.bounds.size ?? .zero)) inflight \(v.frameOwnership.inFlight.map { "\($0.width)x\($0.height)" } ?? "-") fits \(v.fittedGrid.map { "\($0.columns)x\($0.rows)" } ?? "-") state \(name(v.hostFrame(present: false))) presenter \(presenter.debugState(of: v)) missed \(v.frameOwnership.programMissedHold) ptys \(screen.ios[index].resizes.count) last \(grids)]"
        }.joined(separator: " ")
    }

    static func flushLog(_ tag: String) {
        let lines = AnnouncingTerminalIO.log.withLock { log -> [String] in let l = log; log.removeAll(); return l }
        for l in lines { print("DIAG \(tag) io: \(l)") }
    }

    @Test func diagHoldDrag() async throws {
        let screen = try await TerminalResizeProgramHoldTests.ringScreen()
        defer { screen.close() }
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        presenter.presentingHook = { [unowned screen] view, state in
            let name = screen.sessions.firstIndex { $0.surfaceView === view }.map { "p\($0 + 1)" } ?? "?"
            print("DIAG hold present \(name) \(Self.name(state)) epoch \(presenter.currentEpoch) at \(ContinuousClock.now)")
        }
        defer { presenter.presentingHook = nil }
        Self.flushLog("setup")
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        print("DIAG hold start \(Self.line(screen, presenter)) stats \(presenter.stats)")
        view.handleDrag(kind: .split("x"), event: .began(start, []))
        for move in 1...20 {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            print("DIAG hold move \(move) asked epoch \(presenter.currentEpoch) \(Self.line(screen, presenter))")
            await TerminalResizeProgramHoldTests.waitForShownSizes(screen)
            Self.flushLog("move \(move)")
            print("DIAG hold move \(move) shown epoch \(presenter.currentEpoch) \(Self.line(screen, presenter)) stats \(presenter.stats)")
        }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - 120, y: start.y), []))
        await TerminalKeyResizeFrameTests.settle(screen)
        Self.flushLog("end")
        print("DIAG hold end \(Self.line(screen, presenter)) stats \(presenter.stats)")
    }

    @Test func diagM14Drag() async throws {
        let screen = try await TerminalKeyResizeFrameTests.PaneScreen()
        defer { screen.close() }
        await TerminalKeyResizeFrameTests.settle(screen)
        let presenter = TerminalFramePresenter.forWindow(screen.window)
        presenter.presentingHook = { [unowned screen] view, state in
            let name = screen.sessions.firstIndex { $0.surfaceView === view }.map { "p\($0 + 1)" } ?? "?"
            print("DIAG m14 present \(name) \(Self.name(state)) epoch \(presenter.currentEpoch) at \(ContinuousClock.now)")
        }
        defer { presenter.presentingHook = nil }
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("x")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        print("DIAG m14 start \(Self.line(screen, presenter)) stats \(presenter.stats)")
        view.handleDrag(kind: .split("x"), event: .began(start, []))
        let began = ContinuousClock.now
        for move in 1...20 {
            view.handleDrag(kind: .split("x"), event: .moved(CGPoint(x: start.x - CGFloat(move) * 6, y: start.y), []))
            _ = screen.root.advanceFrame(1.0 / 120)
            screen.root.layoutSubtreeIfNeeded() // sync-layout: the stepped frame's own layout pass, as the frame tick runs it
            await TerminalKeyResizeFrameTests.commit()
            print("DIAG m14 move \(move) t+\(began.duration(to: .now)) epoch \(presenter.currentEpoch) \(Self.line(screen, presenter))")
        }
        view.handleDrag(kind: .split("x"), event: .ended(CGPoint(x: start.x - 120, y: start.y), []))
        screen.root.syncWithModel()
        await TerminalKeyResizeFrameTests.settle(screen)
        print("DIAG m14 end \(Self.line(screen, presenter)) stats \(presenter.stats)")
    }
}
