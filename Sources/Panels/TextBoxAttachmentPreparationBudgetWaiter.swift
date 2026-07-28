import Foundation

struct TextBoxAttachmentPreparationBudgetWaiter {
    let id: UUID
    let composerID: UUID
    let reservedBytes: Int
    let continuation: CheckedContinuation<
        TextBoxAttachmentPreparationBudgetPermit?,
        Never
    >
}
