import CmuxNextControl
import CmuxNextWakeupsTestSupport
import Testing

/// A quit step never holds a quit (slow quit, 2026-10-20): a step that hangs costs the quit its limit,
/// and the save steps run in their order, the window saves stopping right after the windows step.
@MainActor
@Suite struct QuitStepLimiterTests {
    @Test func aStepThatEndsInTimeIsMarkedAsEnded() async {
        var marks: [String] = []
        let limiter = QuitStepLimiter(mark: { marks.append($0) }, clock: ManualClock())
        let ended = await limiter.run("fast", limit: .milliseconds(300)) {}
        #expect(ended)
        #expect(marks == ["quit.fast"])
    }

    @Test func aStepThatHangsPassesItsLimitAndTheQuitGoesOn() async throws {
        let clock = ManualClock()
        var marks: [String] = []
        let limiter = QuitStepLimiter(mark: { marks.append($0) }, clock: clock)
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let run = Task { @MainActor in
            await limiter.run("hang", limit: .milliseconds(300)) {
                for await _ in release { break }
            }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(300))
        #expect(await run.value == false, "a hung step held the quit past its limit")
        #expect(marks == ["quit.hang.limit"])
        releaser.finish()
    }

    /// Steps that each record their name; `cloud` runs `cloud` (default: records too).
    static func steps(_ order: @escaping @MainActor (String) -> Void,
                      cloud: @escaping @MainActor () async -> Void = {}) -> QuitSaveSteps {
        QuitSaveSteps(
            remoteSnapshots: { order("remote_snapshots") },
            agentComposers: { order("agent_composers") },
            agentImages: { order("agent_images") },
            terminalFrames: { order("terminal_frames") },
            browserRecords: { order("browser_records") },
            windows: { order("windows") },
            stopSavingWindows: { order("stop_saving_windows") },
            sidebar: { order("sidebar") },
            homeCache: { order("home_cache") },
            cloud: { order("cloud"); await cloud() }
        )
    }

    /// Review of #22919 at c0756ab: the person's own data saves first (browser records, the window
    /// records, the sidebar, Home's drafts and unsent sends, the chat composers), the launch pictures
    /// after them; the window saves stop right after the windows step. Cloud's network work starts
    /// first and runs beside them, so it never delays a save.
    @Test func theSaveStepsRunInOrderAndStopTheWindowSavesAfterTheWindowsStep() async {
        var order: [String] = []
        var marks: [String] = []
        let limiter = QuitStepLimiter(mark: { marks.append($0) }, clock: ManualClock())
        await Self.steps({ order.append($0) }).run(limiter)
        #expect(order == ["cloud", "browser_records", "windows", "stop_saving_windows", "sidebar", "home_cache",
                          "agent_composers", "terminal_frames", "agent_images", "remote_snapshots"])
        #expect(marks == ["quit.browser_records", "quit.windows", "quit.sidebar", "quit.home_cache", "quit.agent_composers",
                          "quit.terminal_frames", "quit.agent_images", "quit.remote_snapshots", "quit.cloud"])
    }

    /// Review of #22919 at c0756ab, finding 1: Cloud's quit work (the Codex broker's stop and the
    /// VM credential revokes, seconds on a slow network) ran before every save, inside the keep quit's
    /// 4 s deadline, so a slow network could end the process before the window records and Home's
    /// cache were saved. A Cloud step that never ends must not hold a single save.
    @Test func aHungCloudStepHoldsNoSave() async throws {
        let clock = ManualClock()
        var order: [String] = []
        let limiter = QuitStepLimiter(mark: { _ in }, clock: clock)
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let run = Task { @MainActor in
            await Self.steps({ order.append($0) }, cloud: { for await _ in release { break } }).run(limiter)
        }
        // No time passes: every save must run while Cloud's step still hangs.
        for _ in 0..<500 where !order.contains("remote_snapshots") { try await Task.sleep(for: .milliseconds(2)) }
        #expect(Set(order).isSuperset(of: ["browser_records", "windows", "sidebar", "home_cache", "agent_composers"]),
                "a hung Cloud step held the saves: \(order)")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        await run.value
        releaser.finish()
    }

    /// Review of #22919 at c0756ab, finding 1: if every step hangs, the quit mark (500 ms), the
    /// "Don't ask again" write and every save step still end inside the keep quit's deadline, with
    /// room left for the engines' stop to begin.
    @Test func everyStepHungStillEndsInsideTheKeepQuitDeadline() {
        let steps = Self.steps { _ in }
        let quitMark: Duration = .milliseconds(500) // AppRunMarker.markQuitting's bound
        let margin: Duration = .milliseconds(400)
        #expect(quitMark + QuitSaveSteps.rememberLimit + steps.worstCase + margin <= QuitDeadline.keepQuitLimit,
                "the step limits (\(steps.worstCase)) do not fit the \(QuitDeadline.keepQuitLimit) deadline")
    }
}
