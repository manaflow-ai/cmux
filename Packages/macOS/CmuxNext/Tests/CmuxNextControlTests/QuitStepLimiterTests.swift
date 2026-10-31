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
        let reached = Reached()
        var order: [String] = []
        let limiter = QuitStepLimiter(mark: { _ in }, clock: clock)
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let run = Task { @MainActor in
            await Self.steps({ order.append($0); reached.saw($0) }, cloud: { for await _ in release { break } }).run(limiter)
        }
        // No time passes: every save must run while Cloud's step still hangs.
        await reached.wait(for: "remote_snapshots")
        #expect(Set(order).isSuperset(of: ["browser_records", "windows", "sidebar", "home_cache", "agent_composers"]),
                "a hung Cloud step held the saves: \(order)")
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        await run.value
        releaser.finish()
    }

    /// Resumes a waiter when a step name is seen (no polling, no real-time sleep).
    @MainActor final class Reached {
        private var seen: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

        func saw(_ name: String) {
            seen.insert(name)
            waiters.removeValue(forKey: name)?.resume()
        }

        func wait(for name: String) async {
            if seen.contains(name) { return }
            await withCheckedContinuation { waiters[name] = $0 }
        }
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

    /// The limiter's marks; `nextLimit()` returns when a step passes its limit (no polling, no real-time sleep).
    @MainActor final class Marks {
        private var seen: [String] = []
        private var waiter: CheckedContinuation<String, Never>?

        func record(_ mark: String) {
            guard mark.hasSuffix(".limit") else { return }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: mark)
            } else {
                seen.append(mark)
            }
        }

        func nextLimit() async -> String {
            if !seen.isEmpty { return seen.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    /// What is left of the quit's deadline, as the test sets it.
    @MainActor final class TimeLeft {
        var value: Duration?
        init(_ value: Duration?) { self.value = value }
    }

    /// The quit's steps with `save` as its one save step `name` (limit 400 ms) and every other step
    /// recorded in `order`.
    static func quit(_ limiter: QuitStepLimiter, timeLeft: TimeLeft, step name: String = "agent_composers",
                     order: @escaping @MainActor (String) -> Void, save: @escaping @MainActor () async -> Void) -> QuitSteps {
        QuitSteps(
            remember: { _ in },
            prepareWindows: { await limiter.run(name, limit: .milliseconds(400), save) },
            endLocalSessions: { order("end_sessions"); return [] },
            confirmFailures: { _ in .quitAnyway },
            endLocalAgents: { order("end_agents"); return [] },
            stopBrowserEngines: { order("engines_stopped") },
            limiter: limiter,
            timeLeft: { timeLeft.value }
        )
    }

    /// Review of #22919 at 0088e20, finding 1: a save step past its limit did not keep running to
    /// the deadline: the quit replied to AppKit once its steps returned, and the process exited
    /// before the late step wrote (one slow chat page lost every chat's composer state). Review at
    /// ce9cd46, note 3: a late `browser_records` step ran on after the browser engines stopped, and
    /// a closed page answers with no back/forward list, so its records would keep only the shown
    /// page. A step that passes its limit but ends before the deadline writes before the engines
    /// stop and before the quit replies.
    @Test(arguments: ["agent_composers", "browser_records"])
    func aStepPastItsLimitStillWritesBeforeTheEnginesStop(step: String) async throws {
        let clock = ManualClock()
        let marks = Marks()
        let limiter = QuitStepLimiter(mark: { marks.record($0) }, clock: clock)
        var order: [String] = []
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, timeLeft: TimeLeft(.seconds(3)), step: step, order: { order.append($0) }, save: {
                for await _ in release { break }
                order.append("written")
            }).run(ends: false, remember: nil)
            order.append("replied")
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        #expect(await marks.nextLimit() == "quit.\(step).limit")
        // The quit now waits for the late step on the clock: nothing after the saves has run.
        try await clock.waitForSleeper()
        #expect(order.isEmpty, "the quit went on past a late save: \(order)")
        releaser.yield()
        releaser.finish()
        await quit.value
        #expect(order == ["written", "engines_stopped", "replied"], "the late save did not come first: \(order)")
    }

    /// The wait for a late step is bounded: a step that never ends holds the quit only for what is
    /// left of its deadline.
    @Test func aStepThatNeverEndsHoldsTheQuitOnlyForTheTimeLeft() async throws {
        let clock = ManualClock()
        let marks = Marks()
        let limiter = QuitStepLimiter(mark: { marks.record($0) }, clock: clock)
        var order: [String] = []
        let timeLeft = TimeLeft(.seconds(3))
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, timeLeft: timeLeft, order: { order.append($0) },
                            save: { for await _ in release { break } }).run(ends: false, remember: nil)
            order.append("replied")
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        #expect(await marks.nextLimit() == "quit.agent_composers.limit")
        try await clock.waitForSleeper()
        #expect(order.isEmpty, "the engines stopped while a save still ran: \(order)")
        // The deadline's time runs out: the quit goes on, and nothing is left for a second wait.
        timeLeft.value = .zero
        clock.advance(by: .seconds(3))
        await quit.value
        #expect(order == ["engines_stopped", "replied"])
        releaser.finish()
    }

    /// Review of #22919 at 0088e20, finding 1: in an End quit a late save (the window records, the
    /// browser records, both through the daemon) must land before the daemon stops.
    @Test func anEndQuitWaitsForALateSaveBeforeItEndsTheSessions() async throws {
        let clock = ManualClock()
        let marks = Marks()
        let limiter = QuitStepLimiter(mark: { marks.record($0) }, clock: clock)
        var order: [String] = []
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, timeLeft: TimeLeft(nil), step: "windows", order: { order.append($0) }, save: {
                for await _ in release { break }
                order.append("windows_written")
            }).run(ends: true, remember: nil)
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        #expect(await marks.nextLimit() == "quit.windows.limit")
        // The End quit now waits for the late save on the clock: no agent or session has ended.
        try await clock.waitForSleeper()
        #expect(order.isEmpty, "the sessions began to end before the late save: \(order)")
        releaser.yield()
        releaser.finish()
        await quit.value
        #expect(order == ["windows_written", "end_agents", "end_sessions", "engines_stopped"], "\(order)")
    }

    /// Review of #22919 at 6f77b0a, note 2: the wait for a late save ran until 200 ms before the
    /// deadline, so a hung save left Chromium no time to close its pages and CefShutdown's last cookie
    /// and storage flush was lost. The engines start to stop with `QuitDeadline.engineCloseWait`
    /// still left.
    @Test func aHungSaveLeavesTheEnginesTheirCloseWait() async throws {
        let clock = ManualClock()
        let marks = Marks()
        let limiter = QuitStepLimiter(mark: { marks.record($0) }, clock: clock)
        var order: [String] = []
        let timeLeft = TimeLeft(.seconds(3))
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let quit = Task { @MainActor in
            await Self.quit(limiter, timeLeft: timeLeft, step: "windows", order: { order.append($0) },
                            save: { for await _ in release { break } }).run(ends: false, remember: nil)
            order.append("replied")
        }
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(400))
        #expect(await marks.nextLimit() == "quit.windows.limit")
        try await clock.waitForSleeper()
        // What the deadline leaves less the engines' close wait: then the engines must stop.
        clock.advance(by: .seconds(3) - QuitDeadline.engineCloseWait)
        try await clock.waitForSleeper()
        #expect(order == ["engines_stopped"], "the engines got less than their close wait: \(order)")
        timeLeft.value = .zero
        clock.advance(by: .seconds(3))
        await quit.value
        #expect(order == ["engines_stopped", "replied"])
        releaser.finish()
    }
}
