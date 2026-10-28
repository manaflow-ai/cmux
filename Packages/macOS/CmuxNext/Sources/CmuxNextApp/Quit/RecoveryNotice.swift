import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// At launch, one toast per recovered draft (R96 quit hook): "Recovered
/// unsaved changes in <title>", with Open (the editor side's
/// `RecoveryDraftStore.restoreHandler`). When the file changed on disk after
/// the draft, the toast says so; a draft never overwrites a file silently.
@MainActor
enum RecoveryNotice {
    /// A recovered draft and whether its file changed on disk since the state its edits are based on.
    typealias Found = (draft: RecoveryDraft, fileChanged: Bool)

    /// Shows the notice after the first window's first frame: an afterFirstFrame post reads
    /// the drafts on the files lane and replies to main with the toasts, so no main job of the notice runs before
    /// that frame (Chrome's AfterStartupTaskUtils::PostTask, chrome/browser/after_startup_task_utils.cc, then
    /// PostTaskAndReplyWithResult, base/task/task_runner.h).
    static func post(store: RecoveryDraftStore, toasts: CmuxToastCenter = .shared, in window: NSWindow,
                     on startup: StartupScheduler, work: BackgroundWork, mainWork: MainWorkScheduler) {
        let directory = store.directory
        startup.post(.afterFirstFrame, "RecoveryNotice.read", on: .main) { [weak store, weak window] in
            guard let store, let window else { return }
            work.run(.userVisible, mayBlock: .files) { () -> [Found] in
                RecoveryDraftFiles.blockingReadAll(in: directory).map { (draft: $0, fileChanged: RecoveryDraftFiles.blockingChangedSince($0)) }
            }.reply(on: mainWork, class: .visible, owner: "RecoveryNotice.show") { [weak store, weak window] found in
                guard let store, let window else { return }
                show(found, store: store, toasts: toasts, in: window)
            }
        }
    }

    /// One toast per draft, oldest first.
    static func show(_ found: [Found], store: RecoveryDraftStore, toasts: CmuxToastCenter, in window: NSWindow) {
        for (draft, fileChanged) in found {
            let message = fileChanged ? QuitStrings.recoveredChanged(draft.title) : QuitStrings.recovered(draft.title)
            let action = store.restoreHandler.map { _ in CmuxToast.Action(title: QuitStrings.recoveredOpen) }
            let handle = toasts.show(CmuxToast(id: "recovery:\(draft.id)", message: message, action: action, duration: .seconds(12)),
                                     in: window)
            handle.onAction = { [weak store] in store?.restoreHandler?(draft) }
        }
    }
}
