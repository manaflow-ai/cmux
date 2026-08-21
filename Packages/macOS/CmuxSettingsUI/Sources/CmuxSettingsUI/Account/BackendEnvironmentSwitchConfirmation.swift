import Foundation

/// The confirm-before-apply state machine behind ``BackendEnvironmentCard``'s
/// picker.
///
/// The picker never writes through on selection: a selection stages the
/// choice here and presents a confirmation dialog, and only an explicit
/// ``confirm()`` hands the staged environment back to the caller to apply.
/// Extracted from the view so the contract (no apply without confirm, pinned
/// builds never stage or present) is testable without rendering SwiftUI.
struct BackendEnvironmentSwitchConfirmation: Equatable {
    /// The staged, not-yet-confirmed picker choice.
    private(set) var pendingSelection: AccountBackendEnvironment?
    /// Whether the confirmation dialog is up for ``pendingSelection``.
    private(set) var isPresentingDialog = false

    /// Handle a picker selection. Selecting the active environment settles
    /// (clears any staged choice); a different environment stages the choice
    /// and presents the dialog. Pinned builds never stage or present.
    mutating func select(
        _ value: AccountBackendEnvironment,
        active: AccountBackendEnvironment,
        pinned: Bool
    ) {
        guard !pinned, value != active else {
            pendingSelection = nil
            isPresentingDialog = false
            return
        }
        pendingSelection = value
        isPresentingDialog = true
    }

    /// The environment the picker row shows: the staged choice while one is
    /// pending, otherwise the active one (so cancel visibly reverts).
    func displayedSelection(active: AccountBackendEnvironment) -> AccountBackendEnvironment {
        pendingSelection ?? active
    }

    /// Dialog cancelled or dismissed: drop the staged choice, reverting the
    /// picker to the active environment.
    mutating func cancel() {
        pendingSelection = nil
        isPresentingDialog = false
    }

    /// Dialog confirmed: consume and return the staged choice for the caller
    /// to apply. Returns `nil` when nothing was staged (already cancelled).
    mutating func confirm() -> AccountBackendEnvironment? {
        defer {
            pendingSelection = nil
            isPresentingDialog = false
        }
        return pendingSelection
    }

    /// The recovery card's named route: stage a switch back to production
    /// through the SAME select/confirm contract as the picker (pinned and
    /// already-on-production requests still never stage or present).
    mutating func requestSwitchBackToProduction(
        active: AccountBackendEnvironment,
        pinned: Bool
    ) {
        select(.production, active: active, pinned: pinned)
    }
}
