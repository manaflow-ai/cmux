/// What a quit saves before any session ends, in this order, each step
/// under its own limit (slow quit, 2026-10-20): a step that hangs (a page
/// that never answers, a daemon that never replies) costs the quit at most
/// its limit, never the whole quit. Together they take about 4.6 s if every
/// one of them hangs, a few hundred ms in practice; a keep quit's deadline
/// (``QuitDeadline/keepQuitLimit``) cuts whatever still runs.
///
/// The App fills each step from its services (`QuitCoordinator`).
public struct QuitSaveSteps {
    /// Remote-terminal tabs keep their last screen for the placeholder after
    /// relaunch (data-model.md 1.4).
    public var remoteSnapshots: @MainActor () async -> Void
    /// Agent chats get their composer's chips, shell command and place back
    /// at the next launch (pages are asked at once, each within a second:
    /// the step's own bound).
    public var agentComposers: @MainActor () async -> Void
    /// Agent panes on screen draw their last page at the next launch.
    public var agentImages: @MainActor () async -> Void
    /// And terminals their last frame.
    public var terminalFrames: @MainActor () async -> Void
    /// Browser tabs reopen at their recorded page (before any session ends,
    /// while the daemon still answers).
    public var browserRecords: @MainActor () async -> Void
    /// Saves the window records and closes incognito windows.
    public var windows: @MainActor () async -> Void
    /// Stops the window saves at once: a windows step past its limit still
    /// runs, and nothing saves from here.
    public var stopSavingWindows: @MainActor () -> Void
    public var sidebar: @MainActor () async -> Void
    /// Home's drafts, scroll places and unsent sends (its cache's last
    /// batch). A write past its limit still runs, and the engine stop awaits
    /// it again.
    public var homeCache: @MainActor () async -> Void

    public init(remoteSnapshots: @escaping @MainActor () async -> Void,
                agentComposers: @escaping @MainActor () async -> Void,
                agentImages: @escaping @MainActor () async -> Void,
                terminalFrames: @escaping @MainActor () async -> Void,
                browserRecords: @escaping @MainActor () async -> Void,
                windows: @escaping @MainActor () async -> Void,
                stopSavingWindows: @escaping @MainActor () -> Void,
                sidebar: @escaping @MainActor () async -> Void,
                homeCache: @escaping @MainActor () async -> Void) {
        self.remoteSnapshots = remoteSnapshots
        self.agentComposers = agentComposers
        self.agentImages = agentImages
        self.terminalFrames = terminalFrames
        self.browserRecords = browserRecords
        self.windows = windows
        self.stopSavingWindows = stopSavingWindows
        self.sidebar = sidebar
        self.homeCache = homeCache
    }

    /// Runs every step in order, each under its limit (`limiter`).
    @MainActor
    public func run(_ limiter: QuitStepLimiter) async {
        await limiter.run("remote_snapshots", limit: .milliseconds(300), remoteSnapshots)
        await limiter.run("agent_composers", limit: .seconds(1), agentComposers)
        await limiter.run("agent_images", limit: .milliseconds(300), agentImages)
        await limiter.run("terminal_frames", limit: .milliseconds(500), terminalFrames)
        await limiter.run("browser_records", limit: .milliseconds(500), browserRecords)
        await limiter.run("windows", limit: .milliseconds(500), windows)
        stopSavingWindows()
        await limiter.run("sidebar", limit: .milliseconds(500), sidebar)
        await limiter.run("home_cache", limit: .milliseconds(500), homeCache)
    }
}
