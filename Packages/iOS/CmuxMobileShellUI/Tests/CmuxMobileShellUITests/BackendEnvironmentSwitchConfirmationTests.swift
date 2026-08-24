#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// The picker's option-set rule: a production-lane build keeps the
/// two-position Production/Staging picker (its "Production" maps to the lane
/// in the app root), every other lane adds a "Build lane (…)" position ahead
/// of the explicit pair.
@Suite
struct MobileBackendEnvironmentSelectionOptionSetTests {
    @Test
    func productionLaneKeepsTheTwoPositionPicker() {
        #expect(MobileBackendEnvironmentSelection.pickerOptions(for: .production)
            == [.production, .staging])
    }

    @Test
    func nonProductionLanesAddTheBuildLanePosition() {
        #expect(MobileBackendEnvironmentSelection.pickerOptions(for: .staging)
            == [.buildLane, .production, .staging])
        #expect(MobileBackendEnvironmentSelection.pickerOptions(
            for: .custom(label: "localhost:9450")
        ) == [.buildLane, .production, .staging])
    }

    @Test
    func optionsResolveTheirEnvironmentAgainstTheLane() {
        // The lane option resolves whatever the lane resolves; the explicit
        // options are lane-independent.
        #expect(MobileBackendEnvironmentSelection.buildLane
            .resolvedEnvironment(lane: .staging) == .staging)
        #expect(MobileBackendEnvironmentSelection.buildLane
            .resolvedEnvironment(lane: .custom(label: "localhost:9450")) == .production)
        #expect(MobileBackendEnvironmentSelection.production
            .resolvedEnvironment(lane: .staging) == .production)
        #expect(MobileBackendEnvironmentSelection.staging
            .resolvedEnvironment(lane: .production) == .staging)
    }
}

/// The confirmation seam behind the Settings backend picker: flipping the
/// picker must never invoke the switch action by itself, confirming invokes it
/// exactly once with the parked target, and cancelling reverts the visible
/// selection to the active option.
@Suite
struct BackendEnvironmentSwitchConfirmationTests {
    @MainActor
    private final class SwitchInvocationRecorder {
        private(set) var targets: [MobileBackendEnvironmentSelection] = []

        func record(_ target: MobileBackendEnvironmentSelection) {
            targets.append(target)
        }

        var action: BackendEnvironmentSwitchAction {
            BackendEnvironmentSwitchAction(phase: .idle) { [weak self] target in
                self?.record(target)
            }
        }
    }

    @Test
    @MainActor
    func pickerSelectionAloneNeverInvokesTheSwitchAction() {
        let recorder = SwitchInvocationRecorder()
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.staging, active: .production)

        // The target is parked behind the dialog; the switch never started.
        #expect(confirmation.pendingTarget == .staging)
        #expect(confirmation.selection(active: .production) == .staging)
        #expect(recorder.targets.isEmpty)
        _ = recorder.action
    }

    @Test
    @MainActor
    func confirmInvokesTheSwitchActionExactlyOnce() {
        let recorder = SwitchInvocationRecorder()
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        confirmation.confirm(using: recorder.action)

        #expect(recorder.targets == [.staging])
        #expect(confirmation.pendingTarget == nil)

        // A second confirm (double-tap, dialog race) has nothing parked and
        // must not start a second switch.
        confirmation.confirm(using: recorder.action)
        #expect(recorder.targets == [.staging])
    }

    @Test
    @MainActor
    func cancelRevertsTheSelectionWithoutInvoking() {
        let recorder = SwitchInvocationRecorder()
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        confirmation.cancel()

        #expect(confirmation.pendingTarget == nil)
        // The picker snaps back to the active option.
        #expect(confirmation.selection(active: .production) == .production)
        #expect(recorder.targets.isEmpty)
        _ = recorder.action
    }

    @Test
    @MainActor
    func reselectingTheActiveOptionClearsThePendingTarget() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)
        #expect(confirmation.pendingTarget == .staging)

        confirmation.select(.production, active: .production)

        #expect(confirmation.pendingTarget == nil)
        #expect(confirmation.selection(active: .production) == .production)
    }

    @Test
    @MainActor
    func confirmWithoutAnInjectedActionOnlyClearsThePendingTarget() {
        // Previews and hosts without the app root inject no action; the
        // dialog must still dismiss cleanly.
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        confirmation.confirm(using: nil)

        #expect(confirmation.pendingTarget == nil)
    }

    @Test
    @MainActor
    func buildLaneTargetRoutesThroughTheSameDialogMachinery() {
        // A device-lane pick in reverse: from explicit staging back to the
        // build lane option on a non-production-lane build. The lane target
        // parks behind the dialog and only confirm begins the switch —
        // exactly once, to `.buildLane` (the app root maps it to clearing
        // the choice).
        let recorder = SwitchInvocationRecorder()
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.buildLane, active: .staging)

        #expect(confirmation.pendingTarget == .buildLane)
        #expect(recorder.targets.isEmpty)

        confirmation.confirm(using: recorder.action)

        #expect(recorder.targets == [.buildLane])
        #expect(confirmation.pendingTarget == nil)
    }

    @Test
    @MainActor
    func recoverySwitchBackRoutesToProductionThroughTheDialog() {
        // The recovery section's "Switch Back to Production" button is the
        // SAME machinery as the picker: it parks `.production` behind the
        // dialog without invoking anything, and only the dialog's confirm
        // begins the switch — exactly once, to production.
        let recorder = SwitchInvocationRecorder()
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.production, active: .staging)

        #expect(confirmation.pendingTarget == .production)
        #expect(recorder.targets.isEmpty)

        confirmation.confirm(using: recorder.action)

        #expect(recorder.targets == [.production])
        #expect(confirmation.pendingTarget == nil)
    }
}

/// The Settings-facing mirror of the transaction phases: every in-flight
/// phase (including the establishing sign-in wait, whose outcome is still
/// undecided) must report running so the picker and the recovery button stay
/// inert until the run resolves.
@Suite
struct BackendEnvironmentSwitchActionPhaseTests {
    @Test
    @MainActor
    func everyInFlightPhaseReportsRunning() {
        let inFlight: [BackendEnvironmentSwitchAction.Phase] = [
            .parking, .retargeting, .establishing, .reverting,
        ]
        for phase in inFlight {
            #expect(BackendEnvironmentSwitchAction(phase: phase) { _ in }.isRunning)
        }
    }

    @Test
    @MainActor
    func idleAndFinishedReportNotRunning() {
        for phase in [BackendEnvironmentSwitchAction.Phase.idle, .finished] {
            #expect(!BackendEnvironmentSwitchAction(phase: phase) { _ in }.isRunning)
        }
    }
}
#endif
