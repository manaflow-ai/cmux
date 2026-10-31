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
        #expect(order.contains("cloud"))
        #expect(order.filter { $0 != "cloud" } == ["browser_records", "windows", "stop_saving_windows", "sidebar", "home_cache",
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
        let margin: Duration = .milliseconds(400)
        #expect(QuitDeadline.quitMarkLimit + QuitSaveSteps.rememberLimit + steps.worstCase + QuitDeadline.replyMargin + margin
                    <= QuitDeadline.keepQuitLimit,
                "the step limits (\(steps.worstCase)) do not fit the \(QuitDeadline.keepQuitLimit) deadline")
    }

    /// The quit's steps with `save` as its one save step (limit 400 ms, the chat composers' in
    /// `QuitSaveSteps`) and every other step recorded in `order`.
    static func quit(_ limiter: QuitStepLimiter, ends: Bool, timeLeft: Duration?, order: @escaping @MainActor (String) -> Void,
                     save: @escaping @MainActor () async -> Void) -> QuitSteps {
        QuitSteps(
            remember: { _ in },
            prepareWindows: { await limiter.run("agent_composers", limit: .milliseconds(400), save) },
            endLocalSessions: { order("end_sessions"); return [] },
            confirmFailures: { _ in .quitAnyway },
            endLocalAgents: { order("end_agents"); return [] },
            stopBrowserEngines: { order("engines_stopped") },
            limiter: limiter,
            timeLeft: { timeLeft }
        )
    }

    /// Review of #22919 at 0088e20, finding 1: a save step past its limit did not keep running to
    /// the deadline: the quit replied to AppKit once its steps returned, and the process exited
    /// before the late step wrote (one slow chat page lost every chat's composer state). A step that
    /// passes its limit but ends before the deadline still writes before the quit returns.
    @Test func aStepPastItsLimitStillWritesBeforeTheQuitReplies() async throws {
        let clock = ManualClock()
        let limiter = QuitStepLimiter(mark: { _ in }, clock: clock)
        var order: [String] = []
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, ends: false, timeLeft: .seconds(3), order: { order.append($0) }, save: {
                for await _ in release { break }
                order.append("composers_written")
            }).run(ends: false, remember: nil)
            order.append("replied")
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        for _ in 0..<500 where !order.contains("engines_stopped") { try await Task.sleep(for: .milliseconds(2)) }
        #expect(order == ["engines_stopped"], "the quit went on past the step's limit: \(order)")
        releaser.yield()
        releaser.finish()
        await quit.value
        #expect(order == ["engines_stopped", "composers_written", "replied"], "the quit replied before the late write: \(order)")
    }

    /// The wait for a late step is bounded: a step that never ends holds the quit only for what is
    /// left of its deadline.
    @Test func aStepThatNeverEndsHoldsTheQuitOnlyForTheTimeLeft() async throws {
        let clock = ManualClock()
        let limiter = QuitStepLimiter(mark: { _ in }, clock: clock)
        var order: [String] = []
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, ends: false, timeLeft: .seconds(3), order: { order.append($0) },
                            save: { for await _ in release { break } }).run(ends: false, remember: nil)
            order.append("replied")
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        for _ in 0..<500 where !order.contains("engines_stopped") { try await Task.sleep(for: .milliseconds(2)) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        await quit.value
        #expect(order == ["engines_stopped", "replied"])
        releaser.finish()
    }

    /// Review of #22919 at 0088e20, finding 1: in an End quit a late save (the window records, the
    /// browser records, both through the daemon) must land before the daemon stops.
    @Test func anEndQuitWaitsForALateSaveBeforeItEndsTheSessions() async throws {
        let clock = ManualClock()
        let limiter = QuitStepLimiter(mark: { _ in }, clock: clock)
        var order: [String] = []
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, ends: true, timeLeft: nil, order: { order.append($0) }, save: {
                for await _ in release { break }
                order.append("windows_written")
            }).run(ends: true, remember: nil)
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(20))
        releaser.yield()
        releaser.finish()
        await quit.value
        #expect(order.first == "windows_written", "the sessions ended before the late save: \(order)")
        #expect(order.contains("end_sessions") && order.last == "engines_stopped")
    }
}
