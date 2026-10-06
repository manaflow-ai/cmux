import CmuxNextDesign
@testable import CmuxNextPages
import Testing

/// R96: page confirmations are cmux dialogs (page script cannot answer
/// them). Return confirms an install; for a removal Return does nothing.
@MainActor
struct PageConfirmationDialogTests {
    @Test func returnConfirmsOnlyNonDestructiveOps() {
        let install = DialogPageConfirmationPresenter.spec(PageConfirmation(kind: .install, name: "Notes"))
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: install) == .press("confirm"))
        let delete = DialogPageConfirmationPresenter.spec(PageConfirmation(kind: .delete, name: "Notes"))
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: delete) == nil)
        #expect(delete.buttons.last?.role == .destructive)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: delete) == .press("cancel"))
    }
}
