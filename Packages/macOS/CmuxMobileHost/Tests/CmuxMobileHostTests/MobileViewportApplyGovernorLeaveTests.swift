import CmuxMobileHost
import Testing

/// A phone that explicitly leaves a terminal (surface closed, back
/// navigation, `mobile.terminal.viewport` clear, disconnect) must give the
/// Mac its size back at once. Only an implicit departure (the TTL of an
/// input-carried report expiring) may wait out the stability window.
@Suite("Mobile viewport governor leave")
struct MobileViewportApplyGovernorLeaveTests {
    @Test func explicitLeaveRestoresTheMacImmediately() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 66, rows: 45))
        #expect(governor.request(.uncapped, immediate: true) == .apply(.uncapped))
        #expect(governor.applied == .uncapped)
        #expect(governor.flush() == nil)
    }

    @Test func explicitLeaveOfOnePhoneAppliesTheRemainingGridImmediately() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 40, rows: 30))
        #expect(
            governor.request(.cap(columns: 66, rows: 45), immediate: true)
                == .apply(.cap(columns: 66, rows: 45))
        )
        #expect(governor.applied == .cap(columns: 66, rows: 45))
    }

    @Test func explicitLeaveCancelsAStagedChange() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 66, rows: 45))
        _ = governor.request(.cap(columns: 60, rows: 40))
        #expect(governor.request(.uncapped, immediate: true) == .apply(.uncapped))
        // The pending window fires later and must not re-apply the stale cap.
        #expect(governor.flush() == nil)
        #expect(governor.applied == .uncapped)
    }

    @Test func explicitLeaveWithNothingAppliedDoesNothing() {
        var governor = MobileViewportApplyGovernor()
        #expect(governor.request(.uncapped, immediate: true) == .drop)
    }

    @Test func implicitExpiryStillWaitsForTheWindow() {
        var governor = MobileViewportApplyGovernor()
        _ = governor.request(.cap(columns: 66, rows: 45))
        #expect(governor.request(.uncapped) == .stage(.uncapped, scheduleFlush: true))
        #expect(governor.flush() == .uncapped)
    }
}
