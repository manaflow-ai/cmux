public import CmuxNextWakeups

/// When the launch starts the Chromium Host (`BrowserBackend.host`, p08-startup-046).
///
/// With the host, Chromium's start holds the main thread only for its shim calls: the host is spawned
/// on the child-process launcher, the remote shim opens and attaches off main, the start's disk reads
/// run off main (`CEFStartInputs`), and `CefInitialize` is an op on its wire. So no idle wait places it; Chrome's visible-first startup rule does
/// (chrome/browser/ui/startup/startup_browser_creator_impl.cc opens the visible tabs first, and
/// chrome/browser/after_startup_task_utils.cc holds the rest): a Chromium page in a shown pane starts
/// the host right after the first frame, a Chromium tab that is only likely (Chromium is the default
/// engine, or a hidden tab is Chromium) after startup, and with neither the host stays unspawned until
/// a Chromium tab asks.
public struct ChromiumHostLaunchStart: Equatable, Sendable {
    /// When the start runs.
    public let priority: StartupPriority
    /// Why Chromium starts (the runtime's trigger).
    public let reason: ChromiumWarmup.Reason

    /// Nil when nothing at launch makes Chromium likely. `hasChromiumTab` walks every tab, so it is
    /// read only when the cheaper reasons do not decide.
    public init?(showsChromiumPane: Bool, defaultIsChromium: Bool, hasChromiumTab: @autoclosure () -> Bool) {
        if showsChromiumPane {
            (priority, reason) = (.afterFirstFrame, .restoredTab)
        } else if defaultIsChromium {
            (priority, reason) = (.afterStartup, .launch)
        } else if hasChromiumTab() {
            (priority, reason) = (.afterStartup, .restoredTab)
        } else {
            return nil
        }
    }
}
