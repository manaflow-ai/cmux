#if canImport(UIKit)
import CMUXMobileCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The keyboard-up top-reveal zone on the LINE scroll path (alternate-screen
/// TUIs). The bottom-pinned full-height render clips its top rows above the
/// screen while the keyboard is up; wheel lines are input for the TUI and can
/// never reach those rows — a short transcript has nothing to scroll at all,
/// and a long one exhausts its history with the grid's top rows still hidden.
/// The line path must resolve the same reveal the pixel path owns: toward
/// older content the reveal fills before any wheel lines dispatch, toward
/// newer it drains first, and with the keyboard down every line reaches the
/// TUI unchanged.
@Suite("Line-path scroll top reveal")
struct LineScrollTopRevealTests {
    @MainActor
    @Test("keyboard-up TUI scroll grants the reveal before any wheel lines")
    func keyboardUpScrollGrantsRevealBeforeWheelLines() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = LineScrollDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }
        view.hostedAltScreenActive = true
        view.setHostedKeyboardState(height: 300, isVisible: true)
        #expect(view.hostedScrollTopRevealBudget == 300)

        // Toward older content (negative deltaY), within the clipped-top
        // budget: the render slides, the TUI sees nothing.
        view.enqueueScrollMechanicsDelta(-120, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()

        #expect(abs(view.hostedScrollTopReveal - 120) < 0.001)
        #expect(delegate.scrollEvents.isEmpty)

        // Past the budget: the reveal clamps full and only the leftover
        // becomes wheel lines (positive = toward older content).
        view.enqueueScrollMechanicsDelta(-300, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()

        #expect(abs(view.hostedScrollTopReveal - 300) < 0.001)
        #expect(!delegate.scrollEvents.isEmpty)
        #expect(delegate.scrollEvents.allSatisfy { $0 > 0 })
    }

    @MainActor
    @Test("scrolling toward newer content drains the reveal before wheeling the TUI")
    func scrollTowardNewerDrainsRevealFirst() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = LineScrollDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }
        view.hostedAltScreenActive = true
        view.setHostedKeyboardState(height: 300, isVisible: true)

        view.enqueueScrollMechanicsDelta(-250, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()
        #expect(abs(view.hostedScrollTopReveal - 250) < 0.001)
        #expect(delegate.scrollEvents.isEmpty)

        // Back toward newer: the granted reveal absorbs the delta; the TUI
        // still sees nothing.
        view.enqueueScrollMechanicsDelta(150, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()

        #expect(abs(view.hostedScrollTopReveal - 100) < 0.001)
        #expect(delegate.scrollEvents.isEmpty)
    }

    @MainActor
    @Test("keyboard-down TUI scrolling is unchanged: every line reaches the app")
    func keyboardDownForwardsAllLines() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = LineScrollDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }
        view.hostedAltScreenActive = true
        #expect(view.hostedScrollTopRevealBudget == 0)

        view.enqueueScrollMechanicsDelta(-120, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()

        #expect(view.hostedScrollTopReveal == 0)
        #expect(!delegate.scrollEvents.isEmpty)
        #expect(delegate.scrollEvents.allSatisfy { $0 > 0 })
    }

    @MainActor
    @Test("the routing clear still drops the held anchor but preserves the reveal")
    func routingClearPreservesRevealWhileDroppingHeldAnchor() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = LineScrollDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }
        view.hostedAltScreenActive = true
        view.setHostedKeyboardState(height: 300, isVisible: true)

        view.enqueueScrollMechanicsDelta(-100, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()
        #expect(abs(view.hostedScrollTopReveal - 100) < 0.001)

        // A primary->alt flip mid-scroll leaves a held pixel anchor behind;
        // the next line-path flush must drop it (it must never drive alt
        // renders) without snapping the presentation-space reveal to zero.
        view.localPixelScrollState.withLock {
            $0.remainderPx = 3
            $0.lastApplied = .init(
                row: 12, remainderPx: 3, positionPx: 245, revision: 7,
                total: 90, rowsPushed: 0, dockedAtTail: false
            )
        }
        view.enqueueScrollMechanicsDelta(-50, touchPoint: CGPoint(x: 12, y: 18))
        _ = await view.drainPendingScrollForVerifiedReplayReveal()

        let state = view.localPixelScrollState.withLock {
            (held: $0.lastApplied, remainder: $0.remainderPx)
        }
        #expect(state.held == nil)
        #expect(state.remainder == 0)
        #expect(abs(view.hostedScrollTopReveal - 150) < 0.001)
    }
}

private final class LineScrollDelegate: NSObject, GhosttySurfaceViewDelegate {
    private(set) var scrollEvents: [Double] = []

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didScrollLines lines: Double,
        atCol col: Int,
        row: Int
    ) {
        scrollEvents.append(lines)
    }
}
#endif
