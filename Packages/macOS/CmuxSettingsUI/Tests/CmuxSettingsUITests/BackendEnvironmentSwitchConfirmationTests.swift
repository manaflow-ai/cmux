import Testing
@testable import CmuxSettingsUI

/// The confirm-before-apply contract behind ``BackendEnvironmentCard``'s
/// picker: a selection never applies without an explicit confirm.
@Suite("BackendEnvironmentSwitchConfirmation")
struct BackendEnvironmentSwitchConfirmationTests {
    @Test func selectionStagesAndPresentsButDoesNotApply() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.staging, active: .production)

        // The only apply path is `confirm()`; selection alone just stages
        // the choice, presents the dialog, and previews the selection.
        #expect(confirmation.pendingSelection == .staging)
        #expect(confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .production) == .staging)
    }

    @Test func confirmConsumesTheStagedChoiceExactlyOnce() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        #expect(confirmation.confirm() == .staging)
        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        // A second confirm (dialog already dismissed) applies nothing.
        #expect(confirmation.confirm() == nil)
    }

    @Test func cancelRevertsTheDisplayedSelectionToActive() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        confirmation.cancel()

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .production) == .production)
        #expect(confirmation.confirm() == nil)
    }

    @Test func selectingTheActiveOptionSettlesWithoutPresenting() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production)

        // Re-picking the active option settles the staged choice.
        confirmation.select(.production, active: .production)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == nil)
    }

    @Test func buildLaneStagesThroughTheSameContract() {
        // The three-position picker's lane option is a first-class staged
        // choice: stage, present, apply only on confirm.
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.buildLane, active: .staging)

        #expect(confirmation.pendingSelection == .buildLane)
        #expect(confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .staging) == .buildLane)
        #expect(confirmation.confirm() == .buildLane)
    }

    @Test func switchBackRequestStagesProductionAndStillRequiresConfirm() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.requestSwitchBackToProduction(active: .staging)

        // The recovery button routes through the SAME staged-confirm
        // contract as the picker: production staged, dialog presented,
        // apply only on confirm.
        #expect(confirmation.pendingSelection == .production)
        #expect(confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == .production)
    }

    @Test func switchBackRequestOnProductionSettlesWithoutPresenting() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.requestSwitchBackToProduction(active: .production)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == nil)
    }
}
