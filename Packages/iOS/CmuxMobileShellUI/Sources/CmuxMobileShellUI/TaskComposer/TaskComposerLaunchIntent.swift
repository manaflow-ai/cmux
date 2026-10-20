#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// Which draft a task-composer session starts from. Drafts are explicit,
/// like X/Twitter: opening the composer always starts fresh, and a saved
/// draft is only loaded by picking it from the drafts list.
enum TaskComposerLaunchIntent: Equatable, Sendable {
    /// Resume one saved draft; starts fresh if it was deleted meanwhile.
    case resume(UUID)
    /// Start a fresh draft.
    case new

    /// Resolves the saved draft this intent restores from `drafts`
    /// (newest first), or `nil` for a fresh composer session.
    func resolveDraft(
        in drafts: [MobileTaskComposerSavedDraft]
    ) -> MobileTaskComposerSavedDraft? {
        switch self {
        case .resume(let id):
            drafts.first { $0.id == id }
        case .new:
            nil
        }
    }
}

/// One composer editing session. The token feeds the presented view's
/// identity, so switching drafts rebuilds the sheet and re-runs its
/// restore-validation init instead of mutating live state in place.
struct TaskComposerLaunch: Equatable, Sendable {
    var token = 0
    var intent: TaskComposerLaunchIntent = .new

    /// The next session for `intent`, always with a fresh view identity.
    func switching(to intent: TaskComposerLaunchIntent) -> TaskComposerLaunch {
        TaskComposerLaunch(token: token + 1, intent: intent)
    }
}
#endif
