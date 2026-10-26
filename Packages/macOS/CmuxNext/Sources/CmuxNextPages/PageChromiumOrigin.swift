import CmuxNextWakeups

/// Why a cmux page starts its Chromium page now: the page side of the engine's tab origin
/// (`BrowserTabConfiguration.origin`, plans/cmux-next/chrome-parity/p08-startup.md, section 3D).
///
/// Chrome loads the visible tab of a session restore at once and the other restored tabs only later,
/// through `TabLoader` (chrome/browser/sessions/session_restore.cc, chrome/browser/sessions/tab_loader.cc),
/// and its startup goal is the first visible WebContents. A cmux page made while the launch runs (Home,
/// New Tab, an agent page in Chromium) follows the same rule in ``PageWebView`` (task p08-startup-041).
public enum PageChromiumOrigin: Sendable, Equatable {
    /// Opened after startup completed (a person's or a script's open): Chromium starts at once.
    case user
    /// Made at launch and shown in a visible window: Chromium starts after the first frame.
    case restoreVisible
    /// Made at launch and not shown before startup completed: Chromium starts then.
    case restoreHidden
}

extension PageChromiumHosting {
    /// ``launch`` while startup has not completed; nil once it has, or with no launch.
    var pendingLaunch: StartupScheduler? {
        guard let launch, launch.completion == nil else { return nil }
        return launch
    }
}
