/// Why a cmux page's Chromium page is made: the page side of the engine's tab origin (`BrowserTabOrigin`,
/// plans/cmux-next/chrome-parity/p08-startup.md section 3D). The host passes it on as
/// `BrowserTabConfiguration.origin`. The engine's one launch order (`CEFLaunchDeferral`) does every launch wait:
/// `CEFEngine.makeTab` for a page that starts, ``PageChromiumHosting/startHidden(when:_:)`` for one that does not show.
///
/// Chrome loads the visible tab of a session restore at once and the other restored tabs only later
/// (chrome/browser/sessions/session_restore.cc, chrome/browser/sessions/tab_loader.cc); its startup goal is the
/// first visible WebContents.
public nonisolated enum PageChromiumOrigin: Sendable, Equatable, CaseIterable {
    /// A person's open: Chromium starts at once (input first).
    case user
    /// A command's, a script's or an agent's open: Chromium starts at once.
    case automation
    /// The launch restored the page and it shows: the engine starts Chromium in an afterFirstFrame post.
    case restoreVisible
    /// The launch restored the page and it does not show: the engine starts Chromium in an afterStartup post.
    case restoreHidden
}

/// Who asked for a page view (``PageOpenRequest/origin``). Only the launch's restore of a tab it restored says
/// ``launchRestore``; every other open is a person's or automation's and starts at once, also while the launch runs.
public nonisolated enum PageOpenOrigin: Sendable, Equatable {
    /// A person's open (a click, a shortcut, a tab they show).
    case user
    /// A command's, a script's or an agent's open.
    case automation
    /// The launch made the page for a tab it restored: its Chromium page follows the launch order
    /// (``PageChromiumHosting/restoredOrigin(isShown:)``), by whether the page shows when it starts.
    case launchRestore
}

extension PageChromiumHosting {
    /// Whether a page the launch restores waits for its launch turn now: the host has a launch order and startup
    /// has not completed.
    var holdsRestoredPages: Bool { restoredOrigin(isShown: false) == .restoreHidden }
}
