@preconcurrency public import Sparkle

/// Opt-in background installs for hosts that never prompt (cmux-next): found updates download
/// silently, and the ready update waits for ``installStagedUpdate()``. Off by default, which
/// keeps the prompt-driven flow and its defaults unchanged. Nothing here writes to defaults.
extension UpdateController {
    /// Whether found updates download without a prompt and wait staged for the user.
    public var installsUpdatesInBackground: Bool {
        get { driver.installsInBackground }
        set { driver.installsInBackground = newValue }
    }

    /// The downloaded update waiting for ``installStagedUpdate()``, or nil.
    public var stagedUpdate: SUAppcastItem? {
        driver.stagedItem
    }

    /// Installs the staged update and relaunches. No-op without one.
    public func installStagedUpdate() {
        driver.installStaged()
    }

    /// Installs the update downloading in the background as soon as it is ready: the user
    /// clicked while it was still downloading.
    public func installWhenStaged() {
        guard driver.stagedInstall == nil else { return driver.installStaged() }
        driver.installsWhenStaged = true
    }
}
