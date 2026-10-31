/// What a quit saves before any session ends, in this order, each step
/// under its own limit (slow quit, 2026-10-20): a step that hangs (a page
/// that never answers, a daemon that never replies) costs the quit at most
/// its limit, never the whole quit. The person's own data saves first
/// (browser records, the window records, the sidebar, Home's drafts and
/// unsent sends, the chat composers), the launch pictures after it. Cloud's
/// network work starts first and runs beside the saves, so a slow network
/// never delays one. If every step hangs they take ``worstCase`` (2.6 s), which fits
/// a keep quit's deadline (``QuitDeadline/keepQuitLimit``) with the quit mark
/// and ``rememberLimit`` before them; in practice a few hundred ms.
///
/// The App fills each step from its services (`QuitCoordinator`).
public struct QuitSaveSteps {
    /// Remote-terminal tabs keep their last screen for the placeholder after
    /// relaunch (data-model.md 1.4).
    public var remoteSnapshots: @MainActor () async -> Void
    /// Agent chats get their composer's chips, shell command and place back
    /// at the next launch (pages are asked at once, each within
    /// `AgentPaneRelaunchWake.askLimit`, below this step's limit; a step past
    /// its limit goes on beside the next steps, and the quit waits for it).
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
    /// Cloud's quit work while its transports still answer: the Codex broker
    /// session stops and the VM credentials it delivered are revoked
    /// (network, up to seconds on a slow network).
    public var cloud: @MainActor () async -> Void

    /// Cloud's step: it ends no local data, so an End quit does not wait for
    /// it before the sessions end (``QuitSteps``).
    public static let cloudStepName = "cloud"

    /// The limit of the "Don't ask again" setting write, before the save steps (`QuitSteps`).
    public static let rememberLimit: Duration = .milliseconds(300)

    public init(remoteSnapshots: @escaping @MainActor () async -> Void,
                agentComposers: @escaping @MainActor () async -> Void,
                agentImages: @escaping @MainActor () async -> Void,
                terminalFrames: @escaping @MainActor () async -> Void,
                browserRecords: @escaping @MainActor () async -> Void,
                windows: @escaping @MainActor () async -> Void,
                stopSavingWindows: @escaping @MainActor () -> Void,
                sidebar: @escaping @MainActor () async -> Void,
                homeCache: @escaping @MainActor () async -> Void,
                cloud: @escaping @MainActor () async -> Void) {
        self.remoteSnapshots = remoteSnapshots
        self.agentComposers = agentComposers
        self.agentImages = agentImages
        self.terminalFrames = terminalFrames
        self.browserRecords = browserRecords
        self.windows = windows
        self.stopSavingWindows = stopSavingWindows
        self.sidebar = sidebar
        self.homeCache = homeCache
        self.cloud = cloud
    }

    /// One step: its name (the `quit.<name>` launch mark), its limit and its work.
    public struct Step {
        public var name: String
        public var limit: Duration
        var body: @MainActor () async -> Void
    }

    /// The save steps in the order ``run(_:)`` runs them, each with its
    /// limit. A step past its limit keeps running beside the next ones.
    public var steps: [Step] {
        [Step(name: "browser_records", limit: .milliseconds(300), body: browserRecords),
         Step(name: "windows", limit: .milliseconds(500), body: windows),
         Step(name: "sidebar", limit: .milliseconds(300), body: sidebar),
         Step(name: "home_cache", limit: .milliseconds(400), body: homeCache),
         Step(name: "agent_composers", limit: .milliseconds(400), body: agentComposers),
         Step(name: "terminal_frames", limit: .milliseconds(200), body: terminalFrames),
         Step(name: "agent_images", limit: .milliseconds(200), body: agentImages),
         Step(name: "remote_snapshots", limit: .milliseconds(200), body: remoteSnapshots)]
    }

    /// How long the save steps wait for Cloud's step once they are done: it
    /// began before them, and past this the quit waits for it with every other
    /// late step, for what is left of the deadline (``QuitSteps``), so this
    /// only marks whether Cloud ended with the saves.
    public var cloudLimit: Duration { .milliseconds(100) }

    /// How long the steps take if every one of them hangs.
    public var worstCase: Duration { steps.reduce(cloudLimit) { $0 + $1.limit } }

    /// Starts Cloud's step, runs every save step in order, each under its
    /// limit (`limiter`), then gives Cloud's step what is left of its limit.
    @MainActor
    public func run(_ limiter: QuitStepLimiter) async {
        // task-owner: Cloud's quit work, awaited below under its limit; it may outlive it, and the process ends at the quit deadline.
        let cloudWork = Task { @MainActor [cloud] in await cloud() }
        for step in steps {
            await limiter.run(step.name, limit: step.limit, step.body)
            // A windows step past its limit still runs; nothing saves windows from here.
            if step.name == "windows" { stopSavingWindows() }
        }
        await limiter.run(Self.cloudStepName, limit: cloudLimit) { await cloudWork.value }
    }
}
