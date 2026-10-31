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

    @Test func theSaveStepsRunInOrderAndStopTheWindowSavesAfterTheWindowsStep() async {
        var order: [String] = []
        var marks: [String] = []
        let limiter = QuitStepLimiter(mark: { marks.append($0) }, clock: ManualClock())
        await QuitSaveSteps(
            remoteSnapshots: { order.append("remote_snapshots") },
            agentComposers: { order.append("agent_composers") },
            agentImages: { order.append("agent_images") },
            terminalFrames: { order.append("terminal_frames") },
            browserRecords: { order.append("browser_records") },
            windows: { order.append("windows") },
            stopSavingWindows: { order.append("stop_saving_windows") },
            sidebar: { order.append("sidebar") },
            homeCache: { order.append("home_cache") }
        ).run(limiter)
        #expect(order == ["remote_snapshots", "agent_composers", "agent_images", "terminal_frames", "browser_records",
                          "windows", "stop_saving_windows", "sidebar", "home_cache"])
        #expect(marks == ["quit.remote_snapshots", "quit.agent_composers", "quit.agent_images", "quit.terminal_frames",
                          "quit.browser_records", "quit.windows", "quit.sidebar", "quit.home_cache"])
    }
}
