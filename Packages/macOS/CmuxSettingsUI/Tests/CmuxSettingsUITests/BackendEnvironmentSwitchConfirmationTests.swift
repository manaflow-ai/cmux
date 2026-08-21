import Testing
@testable import CmuxSettingsUI

/// The confirm-before-apply contract behind ``BackendEnvironmentCard``'s
/// picker: a selection never applies without an explicit confirm, and pinned
/// builds never stage a choice or present the dialog.
@Suite("BackendEnvironmentSwitchConfirmation")
struct BackendEnvironmentSwitchConfirmationTests {
    @Test func selectionStagesAndPresentsButDoesNotApply() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.staging, active: .production, pinned: false)

        // The only apply path is `confirm()`; selection alone just stages
        // the choice, presents the dialog, and previews the selection.
        #expect(confirmation.pendingSelection == .staging)
        #expect(confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .production) == .staging)
    }

    @Test func confirmConsumesTheStagedChoiceExactlyOnce() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production, pinned: false)

        #expect(confirmation.confirm() == .staging)
        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        // A second confirm (dialog already dismissed) applies nothing.
        #expect(confirmation.confirm() == nil)
    }

    @Test func cancelRevertsTheDisplayedSelectionToActive() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production, pinned: false)

        confirmation.cancel()

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .production) == .production)
        #expect(confirmation.confirm() == nil)
    }

    @Test func pinnedBuildsNeverStageOrPresent() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.select(.staging, active: .production, pinned: true)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.displayedSelection(active: .production) == .production)
        #expect(confirmation.confirm() == nil)
    }

    @Test func selectingTheActiveEnvironmentSettlesWithoutPresenting() {
        var confirmation = BackendEnvironmentSwitchConfirmation()
        confirmation.select(.staging, active: .production, pinned: false)

        // Re-picking the active environment settles the staged choice.
        confirmation.select(.production, active: .production, pinned: false)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == nil)
    }

    @Test func switchBackRequestStagesProductionAndStillRequiresConfirm() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.requestSwitchBackToProduction(active: .staging, pinned: false)

        // The recovery button routes through the SAME staged-confirm
        // contract as the picker: production staged, dialog presented,
        // apply only on confirm.
        #expect(confirmation.pendingSelection == .production)
        #expect(confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == .production)
    }

    @Test func pinnedSwitchBackRequestNeverStages() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.requestSwitchBackToProduction(active: .staging, pinned: true)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == nil)
    }

    @Test func switchBackRequestOnProductionSettlesWithoutPresenting() {
        var confirmation = BackendEnvironmentSwitchConfirmation()

        confirmation.requestSwitchBackToProduction(active: .production, pinned: false)

        #expect(confirmation.pendingSelection == nil)
        #expect(!confirmation.isPresentingDialog)
        #expect(confirmation.confirm() == nil)
    }
}
