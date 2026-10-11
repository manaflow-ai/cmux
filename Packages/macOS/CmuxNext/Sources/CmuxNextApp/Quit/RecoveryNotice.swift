import AppKit
import CmuxNextDesign

/// At launch, one toast per recovered draft (R96 quit hook): "Recovered
/// unsaved changes in <title>", with Open (the editor side's
/// `RecoveryDraftStore.restoreHandler`). When the file changed on disk after
/// the draft, the toast says so; a draft never overwrites a file silently.
@MainActor
enum RecoveryNotice {
    static func show(store: RecoveryDraftStore = .shared, toasts: CmuxToastCenter = .shared, in window: NSWindow) async {
        for draft in await store.drafts() {
            let message = await message(for: draft, store: store)
            let action = store.restoreHandler.map { _ in CmuxToast.Action(title: QuitStrings.recoveredOpen) }
            let handle = toasts.show(CmuxToast(id: "recovery:\(draft.id)", message: message, action: action, duration: .seconds(12)),
                                     in: window)
            handle.onAction = { [weak store] in store?.restoreHandler?(draft) }
        }
    }

    /// The toast's text: it says so when the file changed on disk since the
    /// state the draft's edits are based on.
    static func message(for draft: RecoveryDraft, store: RecoveryDraftStore) async -> String {
        await store.fileChangedSince(draft) ? QuitStrings.recoveredChanged(draft.title) : QuitStrings.recovered(draft.title)
    }
}
