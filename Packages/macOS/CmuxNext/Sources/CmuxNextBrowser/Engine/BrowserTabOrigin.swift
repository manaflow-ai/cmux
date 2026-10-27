/// Why a browser tab is made (p08-startup.md section 3D), which orders its Chromium start at launch as
/// Chrome orders session restore: the visible tab first, the rest after startup
/// (chrome/browser/sessions/tab_loader.cc, chrome/browser/after_startup_task_utils.cc). ``CEFLaunchDeferral``
/// applies it.
public nonisolated enum BrowserTabOrigin: String, Hashable, Sendable, CaseIterable {
    /// The person opened or showed it: Chromium starts at once (input first).
    case user
    /// A command, a script or an agent asked for it now: Chromium starts at once.
    case automation
    /// The launch restored it in a visible window: Chromium starts right after the first frame.
    case restoreVisible
    /// The launch restored it where it does not show: it waits for startup complete.
    case restoreHidden
}
