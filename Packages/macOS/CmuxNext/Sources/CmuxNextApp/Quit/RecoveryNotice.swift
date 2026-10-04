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
            let changed = await store.fileChangedSince(draft)
            let message = changed ? QuitStrings.recoveredChanged(draft.title) : QuitStrings.recovered(draft.title)
            let action = store.restoreHandler.map { _ in CmuxToast.Action(title: QuitStrings.recoveredOpen) }
            let handle = toasts.show(CmuxToast(id: "recovery:\(draft.id)", message: message, action: action, duration: .seconds(12)),
                                     in: window)
            handle.onAction = { [weak store] in store?.restoreHandler?(draft) }
        }
    }
}
