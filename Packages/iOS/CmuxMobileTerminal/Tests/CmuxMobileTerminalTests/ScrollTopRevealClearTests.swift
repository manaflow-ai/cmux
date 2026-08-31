#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// The keyboard-leg reveal clear must behave like every other
/// pixel-authority clear: an epoch bump invalidates in-flight batches whose
/// captured budget predates the leg, so they cannot re-commit the cleared
/// reveal after the leg seats the cap. With no reveal granted the clear is a
/// no-op, so ordinary keyboard toggles never perturb an active gesture's
/// scroll authority.
@Suite("Scroll top-reveal clear")
struct ScrollTopRevealClearTests {
    @MainActor
    @Test("clearing a granted reveal bumps the epoch so stale batches cannot restore it")
    func clearingGrantedRevealBumpsEpoch() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RevealClearDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }

        let staleEpoch = view.localPixelScrollState.withLock { state -> UInt64 in
            state.topRevealPx = 240
            state.remainderPx = 3
            state.lastApplied = .init(row: 0, remainderPx: 0, positionPx: 0, revision: 7, total: 90, rowsPushed: 0, dockedAtTail: false)
            return state.epoch
        }

        view.clearHostedScrollTopReveal()

        let cleared = view.localPixelScrollState.withLock { state in
            (epoch: state.epoch, reveal: state.topRevealPx, remainder: state.remainderPx, held: state.lastApplied)
        }
        #expect(cleared.epoch != staleEpoch)
        #expect(cleared.reveal == 0)
        #expect(cleared.remainder == 0)
        #expect(cleared.held == nil)
        #expect(view.hostedScrollTopReveal == 0)
    }

    @MainActor
    @Test("clearing with no granted reveal is a no-op for the scroll authority")
    func clearingWithoutRevealPreservesScrollAuthority() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RevealClearDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        defer { view.prepareForDismantle() }

        let seeded = view.localPixelScrollState.withLock { state -> UInt64 in
            state.remainderPx = 5
            state.lastApplied = .init(row: 12, remainderPx: 5, positionPx: 245, revision: 7, total: 90, rowsPushed: 0, dockedAtTail: false)
            return state.epoch
        }

        view.clearHostedScrollTopReveal()

        let after = view.localPixelScrollState.withLock { state in
            (epoch: state.epoch, remainder: state.remainderPx, heldRow: state.lastApplied?.row)
        }
        #expect(after.epoch == seeded)
        #expect(after.remainder == 5)
        #expect(after.heldRow == 12)
    }
}

private final class RevealClearDelegate: NSObject, GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {}
}
#endif
