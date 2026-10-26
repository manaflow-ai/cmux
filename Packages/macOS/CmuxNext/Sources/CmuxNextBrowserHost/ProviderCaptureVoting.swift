public import CmuxNextWakeups

/// The app's tab nodes for agent captures (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// section B, task 211): an agent's screenshot or screencast of a tab nobody sees takes a vote on
/// the tab's ``VisibilityNode`` that stays hidden, so the tab renders for the capture while its page
/// still reads hidden. Chromium's DevTools page handler holds
/// `WebContents::IncrementCapturerCount(size, /*stay_hidden=*/true, ...)` the same way
/// (content/browser/devtools/protocol/page_handler.cc).
@MainActor
public protocol ProviderCaptureVoting: AnyObject {
    /// A vote on tab `targetID`'s node, held until the caller releases it; nil for a tab the app does
    /// not announce.
    func captureVote(targetID: String, reason: String) -> VisibilityCaptureVote?
}
