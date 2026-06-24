import AppKit
import Foundation

/// Pure builder for the crash-recovery offer's copy. Separated from presentation
/// so the wording/gating is testable without an app host.
enum CrashRecoveryOfferText {
    struct Content: Equatable {
        var title: String
        var message: String
        var resumeButton: String
        var dismissButton: String
    }

    static func make(resumableCount: Int) -> Content {
        Content(
            title: String(
                localized: "crashRecovery.offer.title",
                defaultValue: "Resume where you left off?"
            ),
            message: String(
                format: String(
                    localized: "crashRecovery.offer.message",
                    defaultValue: "cmux didn't shut down cleanly last time. Pick up where the agents left off in %lld workspace(s)?"
                ),
                resumableCount
            ),
            resumeButton: String(localized: "crashRecovery.offer.resume", defaultValue: "Resume"),
            dismissButton: String(localized: "common.notNow", defaultValue: "Not Now")
        )
    }
}

/// Presents the Chrome-style "you crashed — resume?" offer at launch and, on
/// accept, resumes every resumable workspace. Gated on a real crash + opt-in
/// (`CrashRecoveryLaunchState.shouldOfferResume`). The decision logic lives in
/// the planner/launch-state; this is thin AppKit glue.
@MainActor
enum CrashRecoveryOfferPresenter {
    /// Resumable workspaces in the manager (those whose focused surface can be
    /// resumed). Exposed for the presenter and for tests of the partitioning.
    static func resumableWorkspaces(
        in manager: TabManager,
        defaults: UserDefaults = .standard
    ) -> [Workspace] {
        manager.tabs.filter { $0.canResumeWhereWeLeftOff(defaults: defaults) }
    }

    /// Shows the offer once after restore, if the prior run crashed and the user
    /// opted in and there is something resumable. On accept, resumes all.
    static func presentOfferIfNeeded(
        in manager: TabManager,
        launchState: CrashRecoveryLaunchState = .shared,
        defaults: UserDefaults = .standard
    ) {
        guard launchState.shouldOfferResume(defaults: defaults) else { return }
        let resumable = resumableWorkspaces(in: manager, defaults: defaults)
        guard !resumable.isEmpty else { return }

        let content = CrashRecoveryOfferText.make(resumableCount: resumable.count)
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.addButton(withTitle: content.resumeButton)
        alert.addButton(withTitle: content.dismissButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for workspace in resumable {
            _ = workspace.resumeWhereWeLeftOff(defaults: defaults)
        }
    }
}
