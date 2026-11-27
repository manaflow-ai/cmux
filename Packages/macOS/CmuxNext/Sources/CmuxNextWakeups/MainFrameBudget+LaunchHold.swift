extension MainFrameBudget {
    /// Holds background work until ``releaseLaunchHold()`` (CMUX-629; Leo: "technically only need to draw that one
    /// workspace open and the sidebar"): set at the composition root before anything is queued, so nothing nobody
    /// sees (the next Cmd-N's workspace, the pane spare, the binding table warm-up) runs until the open workspace is
    /// live. The app ends it at the launch settle, or its backstop (`LaunchBackgroundHold`). Queued work stays queued
    /// and runs from the next frame on; it waits even past ``Budgets/idleTimeout``.
    public func holdBackgroundForLaunch() { holdsBackgroundForLaunch = true }

    /// Ends the launch hold (later calls do nothing).
    public func releaseLaunchHold() { holdsBackgroundForLaunch = false }
}
