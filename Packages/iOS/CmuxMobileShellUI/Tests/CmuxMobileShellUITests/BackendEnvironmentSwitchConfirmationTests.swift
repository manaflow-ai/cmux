#if os(iOS)
import CMUXAuthCore
import Testing
@testable import CmuxMobileShellUI

/// The confirmation seam behind the Settings backend picker: flipping the
/// picker must never invoke the switch action by itself, confirming invokes it
/// exactly once with the parked target, and cancelling reverts the visible
/// selection to the active environment.
@Suite
struct BackendEnvironmentSwitchConfirmationTests {
    @MainActor
    private final class SwitchInvocationRecorder {
        private(set) var targets: [CMUXBackendEnvironmentOverride] = []

        func record(_ target: CMUXBackendEnvironmentOverride) {
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
        // The picker snaps back to the active environment.
        #expect(confirmation.selection(active: .production) == .production)
        #expect(recorder.targets.isEmpty)
        _ = recorder.action
    }

    @Test
    @MainActor
    func reselectingTheActiveEnvironmentClearsThePendingTarget() {
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
}
#endif
