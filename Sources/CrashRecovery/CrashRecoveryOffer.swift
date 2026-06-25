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
            message: String.localizedStringWithFormat(
                String(
                    localized: "crashRecovery.offer.message",
                    defaultValue: "cmux didn't shut down cleanly last time. Pick up where the agents left off in %lld workspaces?"
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
        resumableWorkspaces(in: [manager], defaults: defaults)
    }

    /// Resumable workspaces across every restored main-window manager. Managers
    /// and workspaces are de-duplicated defensively because launch wiring has
    /// several fallback routes to the active manager.
    static func resumableWorkspaces(
        in managers: [TabManager],
        defaults: UserDefaults = .standard
    ) -> [Workspace] {
        var seenManagers = Set<ObjectIdentifier>()
        var seenWorkspaces = Set<ObjectIdentifier>()
        var workspaces: [Workspace] = []
        for manager in managers where seenManagers.insert(ObjectIdentifier(manager)).inserted {
            for workspace in manager.tabs where workspace.canResumeWhereWeLeftOff(defaults: defaults) {
                guard seenWorkspaces.insert(ObjectIdentifier(workspace)).inserted else { continue }
                workspaces.append(workspace)
            }
        }
        return workspaces
    }

    /// Shows the offer once after restore, if the prior run crashed and the user
    /// opted in and there is something resumable. On accept, resumes all.
    static func presentOfferIfNeeded(
        in manager: TabManager,
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) {
        presentOfferIfNeeded(in: [manager], launchState: launchState, defaults: defaults)
    }

    /// Shows the launch offer for all restored windows, if the prior run crashed
    /// and the user opted in. On accept, resumes every eligible workspace.
    static func presentOfferIfNeeded(
        in managers: [TabManager],
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) {
        guard launchState.shouldOfferResume(defaults: defaults) else { return }
        let resumable = resumableWorkspaces(in: managers, defaults: defaults)
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

    /// After an intentional relaunch (Sparkle update), silently auto-resume agents
    /// when the user opted in (`resumeAgentsAfterUpdate`). No prompt — the relaunch
    /// was deliberate. Windows always restore regardless; this only resumes agents.
    static func resumeAfterIntentionalRelaunchIfNeeded(
        in manager: TabManager,
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) {
        resumeAfterIntentionalRelaunchIfNeeded(in: [manager], launchState: launchState, defaults: defaults)
    }

    /// After an intentional relaunch, silently auto-resume agents in every
    /// restored main window when the user opted in.
    static func resumeAfterIntentionalRelaunchIfNeeded(
        in managers: [TabManager],
        launchState: CrashRecoveryLaunchState,
        defaults: UserDefaults = .standard
    ) {
        guard launchState.restoreWasIntended,
              CrashRecoverySettings.resumeAgentsAfterUpdate(defaults: defaults) else { return }
        for workspace in resumableWorkspaces(in: managers, defaults: defaults) {
            _ = workspace.resumeWhereWeLeftOff(defaults: defaults)
        }
    }
}
