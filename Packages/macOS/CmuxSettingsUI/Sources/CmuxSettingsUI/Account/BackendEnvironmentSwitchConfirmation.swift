import Foundation

/// The confirm-before-apply state machine behind ``BackendEnvironmentCard``'s
/// picker.
///
/// The picker never writes through on selection: a selection stages the
/// choice here and presents a confirmation dialog, and only an explicit
/// ``confirm()`` hands the staged selection back to the caller to apply.
/// Extracted from the view so the contract (no apply without confirm) is
/// testable without rendering SwiftUI. Selections are the picker's option
/// mirror (`.buildLane` / `.production` / `.staging`); the host maps them to
/// its own lane/explicit model on apply.
struct BackendEnvironmentSwitchConfirmation: Equatable {
    /// The staged, not-yet-confirmed picker choice.
    private(set) var pendingSelection: AccountBackendEnvironmentSelection?
    /// Whether the confirmation dialog is up for ``pendingSelection``.
    private(set) var isPresentingDialog = false

    /// Handle a picker selection. Selecting the active option settles
    /// (clears any staged choice); a different option stages the choice and
    /// presents the dialog.
    mutating func select(
        _ value: AccountBackendEnvironmentSelection,
        active: AccountBackendEnvironmentSelection
    ) {
        guard value != active else {
            pendingSelection = nil
            isPresentingDialog = false
            return
        }
        pendingSelection = value
        isPresentingDialog = true
    }

    /// The option the picker row shows: the staged choice while one is
    /// pending, otherwise the active one (so cancel visibly reverts).
    func displayedSelection(
        active: AccountBackendEnvironmentSelection
    ) -> AccountBackendEnvironmentSelection {
        pendingSelection ?? active
    }

    /// Dialog cancelled or dismissed: drop the staged choice, reverting the
    /// picker to the active option.
    mutating func cancel() {
        pendingSelection = nil
        isPresentingDialog = false
    }

    /// Dialog confirmed: consume and return the staged choice for the caller
    /// to apply. Returns `nil` when nothing was staged (already cancelled).
    mutating func confirm() -> AccountBackendEnvironmentSelection? {
        defer {
            pendingSelection = nil
            isPresentingDialog = false
        }
        return pendingSelection
    }

    /// The recovery card's named route: stage a switch back to production
    /// through the SAME select/confirm contract as the picker (an
    /// already-on-production request still never stages or presents).
    mutating func requestSwitchBackToProduction(
        active: AccountBackendEnvironmentSelection
    ) {
        select(.production, active: active)
    }
}
