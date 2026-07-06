import CmuxFleet
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct FleetEngineTests {
    @Test
    func createFleetValidatesAndPersistsConfiguration() throws {
        let harness = FleetEngineHarness()
        let engine = harness.engine()
        let tempRoot = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        #expect(engine.createFleet(name: "", repoRoot: tempRoot.path, agentCommandTemplate: nil, maxConcurrent: nil)
            == .failure(.invalidConfiguration("Fleet name is required")))
        #expect(engine.createFleet(name: "Fleet", repoRoot: tempRoot.appendingPathComponent("missing").path, agentCommandTemplate: nil, maxConcurrent: nil)
            == .failure(.invalidConfiguration("Repository root must be an existing directory")))

        let config = try engine.createFleet(name: "Fleet", repoRoot: tempRoot.path, agentCommandTemplate: nil, maxConcurrent: nil).get()
        #expect(config.id == FleetID(FleetPathSanitizer().directoryName(for: "Fleet")))
        #expect(config.workspaceRoot == tempRoot.deletingLastPathComponent().appendingPathComponent("\(tempRoot.lastPathComponent)-fleet").path)
        #expect(engine.createFleet(name: "fleet", repoRoot: tempRoot.path, agentCommandTemplate: nil, maxConcurrent: nil)
            == .failure(.invalidConfiguration("Fleet name already exists")))
        #expect(harness.persistence.saved.last?.fleets.first?.config == config)
        #expect(harness.persistence.saved.last?.fleets.first?.isRunning == false)
    }

    @Test
    func runningFleetProvisionsLaunchesAndRecordsSessionStart() async throws {
        let harness = FleetEngineHarness()
        let engine = harness.engine()
        let fleet = try Self.createFleet(engine, repoRoot: try Self.tempDirectory(), template: "claude {{PROMPT}}")
        let task = try engine.addTask(fleetID: fleet.id, title: "Fix Bob's bug", body: "Don't fail", priority: nil).get()

        #expect(engine.startFleet(id: fleet.id))
        await Task.yield()
        await Task.yield()

        let launched = try #require(try engine.tasks(fleetID: fleet.id, state: .launching).get().first?.task)
        #expect(launched.workspaceID == "workspace-\(task.id.rawValue)")
        #expect(launched.surfaceID == "surface-\(task.id.rawValue)")
        #expect(launched.branch == "fleet/task")
        #expect(harness.actuator.sendAgentCommandTexts == ["claude 'Fix Bob'\\''s bug\n\nDon'\\''t fail'\n"])

        engine.noteWorkstreamHook(workspaceID: launched.workspaceID!, sessionID: "s1", pid: 42, kind: .sessionStart, at: harness.dateBox.now)
        let running = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task)
        #expect(running.id == task.id)
        #expect(harness.processWatcher.watched == [42])
    }

    @Test
    func needsInputNotificationAndToolUseResolution() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask()
        let running = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task)

        engine.noteWorkstreamHook(workspaceID: running.workspaceID!, sessionID: nil, pid: nil, kind: .blockingRequest, at: harness.dateBox.now)
        let needsInput = try #require(try engine.tasks(fleetID: fleet.id, state: .needsInput).get().first?.task)
        #expect(needsInput.id == task.id)
        #expect(harness.actuator.notifications.map(\.kind) == [.needsInput])

        engine.noteWorkstreamHook(workspaceID: running.workspaceID!, sessionID: nil, pid: nil, kind: .toolUse, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.id == task.id)
    }

    @Test
    func stopHookIsActivitySessionEndRetriesAndEventuallyFails() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask()
        let workspaceID = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.workspaceID)

        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .stop, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.id == task.id)

        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .retryBackoff).get().first?.task.id == task.id)
        harness.timers.fire("backoff:\(task.id.rawValue):1")
        #expect(harness.actuator.sendAgentCommandTexts.count == 2)

        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: "s2", pid: nil, kind: .sessionStart, at: harness.dateBox.now)
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        harness.timers.fire("backoff:\(task.id.rawValue):2")
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: "s3", pid: nil, kind: .sessionStart, at: harness.dateBox.now)
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)

        #expect(try engine.tasks(fleetID: fleet.id, state: .failed).get().first?.task.id == task.id)
    }

    @Test
    func pidExitAndStalePidExitAreAttemptScoped() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask(pid: 10)
        harness.processWatcher.fire(pid: 10)
        #expect(try engine.tasks(fleetID: fleet.id, state: .retryBackoff).get().first?.task.id == task.id)

        harness.timers.fire("backoff:\(task.id.rawValue):1")
        let launching = try #require(try engine.tasks(fleetID: fleet.id, state: .launching).get().first?.task)
        engine.noteWorkstreamHook(workspaceID: launching.workspaceID!, sessionID: "s2", pid: 11, kind: .sessionStart, at: harness.dateBox.now)
        harness.processWatcher.fire(pid: 10)
        #expect(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.id == task.id)
    }

    @Test
    func pullRequestHandoffAndMergedCleanup() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask()
        let running = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task)
        harness.world.existingWorkspaces.insert(running.workspaceID!)
        harness.world.pullRequests[running.workspaceID!] = FleetPullRequestStatus(
            number: 7,
            url: URL(string: "https://example.com/pr/7"),
            state: .open
        )
        harness.timers.fire("reconcile")
        #expect(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.pr?.state == .open)

        engine.noteWorkstreamHook(workspaceID: running.workspaceID!, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .awaitingReview).get().first?.task.id == task.id)
        #expect(harness.actuator.closes.isEmpty)

        harness.world.pullRequests[running.workspaceID!] = FleetPullRequestStatus(
            number: 7,
            url: URL(string: "https://example.com/pr/7"),
            state: .merged
        )
        harness.timers.fire("reconcile")
        #expect(try engine.tasks(fleetID: fleet.id, state: .done).get().first?.task.id == task.id)
        #expect(harness.actuator.closes == [running.workspaceID!])
    }

    @Test
    func reconcileRescuesFailedTaskToAwaitingReviewWhenPullRequestOpens() async throws {
        let (harness, engine, fleet, task, workspaceID) = try await Self.failedTask()

        harness.world.pullRequests[workspaceID] = FleetPullRequestStatus(
            number: 7,
            url: URL(string: "https://example.com/pr/7"),
            state: .open
        )
        harness.timers.fire("reconcile")

        let awaiting = try #require(try engine.tasks(fleetID: fleet.id, state: .awaitingReview).get().first?.task)
        #expect(awaiting.id == task.id)
        #expect(awaiting.pr?.state == .open)
        #expect(harness.actuator.closes.isEmpty)
    }

    @Test
    func reconcileRescuesFailedTaskToDoneWhenPullRequestMerged() async throws {
        let (harness, engine, fleet, task, workspaceID) = try await Self.failedTask()

        harness.world.pullRequests[workspaceID] = FleetPullRequestStatus(
            number: 7,
            url: URL(string: "https://example.com/pr/7"),
            state: .merged
        )
        harness.timers.fire("reconcile")

        let done = try #require(try engine.tasks(fleetID: fleet.id, state: .done).get().first?.task)
        #expect(done.id == task.id)
        #expect(done.pr?.state == .merged)
        #expect(harness.actuator.closes == [workspaceID])
    }

    @Test
    func schedulerCapCancelRetryOpenAndUnknownHooks() async throws {
        let harness = FleetEngineHarness()
        let engine = harness.engine()
        let fleet = try Self.createFleet(engine, repoRoot: try Self.tempDirectory(), maxConcurrent: 1)
        let first = try engine.addTask(fleetID: fleet.id, title: "one", body: nil, priority: 0).get()
        let second = try engine.addTask(fleetID: fleet.id, title: "two", body: nil, priority: 1).get()

        #expect(engine.startFleet(id: fleet.id))
        await Task.yield()
        await Task.yield()
        #expect(harness.actuator.provisionCalls.map(\.taskID) == [first.id])

        let launched = try #require(try engine.tasks(fleetID: fleet.id, state: .launching).get().first?.task)
        #expect(engine.openTarget(taskID: first.id) == .workspace(launched.workspaceID!))
        #expect(engine.openTarget(taskID: second.id) == .noWorkspace)
        #expect(engine.openTarget(taskID: "missing") == .notFound)
        engine.noteWorkstreamHook(workspaceID: "unknown", sessionID: nil, pid: nil, kind: .sessionStart, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .launching).get().first?.task.id == first.id)

        #expect(engine.cancelTask(id: first.id).isOK)
        #expect(harness.actuator.kills.count == 1)
        await Task.yield()
        await Task.yield()
        #expect(harness.actuator.provisionCalls.map(\.taskID) == [first.id, second.id])

        _ = engine.cancelTask(id: second.id)
        #expect(engine.retryTask(id: second.id).isOK)
        await Task.yield()
        await Task.yield()
        #expect(harness.actuator.provisionCalls.map(\.taskID).contains(second.id))
    }

    @Test
    func cancelDuringProvisionDropsStaleOutcomeAndClosesOrphanWorkspace() async throws {
        let harness = FleetEngineHarness()
        let engine = harness.engine()
        let fleet = try Self.createFleet(engine, repoRoot: try Self.tempDirectory())
        let task = try engine.addTask(fleetID: fleet.id, title: "stale", body: nil, priority: nil).get()
        harness.actuator.suspendProvision(for: task.id)

        #expect(engine.startFleet(id: fleet.id))
        await Task.yield()
        await Task.yield()
        #expect(harness.actuator.provisionCalls.map(\.taskID) == [task.id])
        #expect(try engine.tasks(fleetID: fleet.id, state: .provisioning).get().first?.task.id == task.id)

        #expect(engine.cancelTask(id: task.id).isOK)
        let orphan = FleetProvisionOutcome(
            workspaceID: "orphan-workspace",
            surfaceID: "orphan-surface",
            directoryPath: "/tmp/orphan",
            branch: "fleet/orphan",
            isBrandNew: true
        )
        harness.actuator.completeProvision(taskID: task.id, result: .success(orphan))
        await Task.yield()
        await Task.yield()

        let cancelled = try #require(try engine.tasks(fleetID: fleet.id, state: .cancelled).get().first?.task)
        #expect(cancelled.workspaceID == nil)
        #expect(cancelled.surfaceID == nil)
        #expect(cancelled.branch == nil)
        #expect(engine.openTarget(taskID: task.id) == .noWorkspace)
        #expect(harness.actuator.closes == ["orphan-workspace"])
        #expect(harness.actuator.sendAgentCommandTexts.isEmpty)
    }

    @Test
    func reconcileWorkspaceGonePromptIdleStallAndPersistenceRestore() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask()
        let running = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task)

        harness.world.existingWorkspaces.remove(running.workspaceID!)
        harness.timers.fire("reconcile")
        #expect(try engine.tasks(fleetID: fleet.id, state: .cancelled).get().first?.task.id == task.id)

        let restorePersistence = FakeFleetPersistence()
        restorePersistence.loadState = FleetPersistedState(fleets: [
            FleetPersistedFleet(config: fleet, isRunning: true, tasks: [running]),
        ])
        let restoreHarness = FleetEngineHarness()
        restoreHarness.persistence.loadState = restorePersistence.loadState
        restoreHarness.dateBox.now = harness.dateBox.now
        restoreHarness.world.existingWorkspaces.insert(running.workspaceID!)
        let restored = FleetEngine(dependencies: FleetEngineDependencies(
            actuator: restoreHarness.actuator,
            world: restoreHarness.world,
            timers: restoreHarness.timers,
            processWatcher: restoreHarness.processWatcher,
            persistence: restoreHarness.persistence,
            now: { restoreHarness.dateBox.now }
        ))
        #expect(restored.isFleetRunning(id: fleet.id) == false)
        #expect(try restored.tasks(fleetID: fleet.id, state: nil).get().first?.task.id == task.id)

        _ = restored.startFleet(id: fleet.id)
        restoreHarness.world.promptIdle["\(running.workspaceID!)|\(running.surfaceID!)"] = true
        restoreHarness.timers.fire("reconcile")
        #expect(try restored.tasks(fleetID: fleet.id, state: .running).get().first?.task.id == task.id)

        restoreHarness.dateBox.advance(seconds: 121)
        restoreHarness.timers.fire("reconcile")
        #expect(try restored.tasks(fleetID: fleet.id, state: .retryBackoff).get().first?.task.id == task.id)

        restoreHarness.timers.fire("backoff:\(task.id.rawValue):1")
        let relaunching = try #require(try restored.tasks(fleetID: fleet.id, state: .launching).get().first?.task)
        restoreHarness.timers.fire("stall:\(task.id.rawValue):1")
        #expect(try restored.tasks(fleetID: fleet.id, state: .launching).get().first?.task.id == task.id)
        restoreHarness.timers.fire("stall:\(task.id.rawValue):\(relaunching.attempts)")
        #expect(restoreHarness.actuator.kills.count >= 1)
    }

    @Test
    func hooksForCancelledTasksAreIgnored() async throws {
        let (harness, engine, fleet, task) = try await Self.runningTask()
        let running = try #require(try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task)

        #expect(engine.cancelTask(id: task.id).isOK)
        let notificationCount = harness.actuator.notifications.count
        engine.noteWorkstreamHook(
            workspaceID: running.workspaceID!,
            sessionID: nil,
            pid: nil,
            kind: .blockingRequest,
            at: harness.dateBox.now
        )

        #expect(try engine.tasks(fleetID: fleet.id, state: .cancelled).get().first?.task.id == task.id)
        #expect(harness.actuator.notifications.count == notificationCount)
    }

    private static func createFleet(
        _ engine: FleetEngine,
        repoRoot: URL,
        template: String? = nil,
        maxConcurrent: Int? = nil
    ) throws -> FleetConfig {
        try engine.createFleet(
            name: "Fleet",
            repoRoot: repoRoot.path,
            agentCommandTemplate: template,
            maxConcurrent: maxConcurrent
        ).get()
    }

    private static func runningTask(pid: Int32? = nil) async throws -> (
        FleetEngineHarness,
        FleetEngine,
        FleetConfig,
        FleetTask
    ) {
        let harness = FleetEngineHarness()
        let engine = harness.engine()
        let fleet = try createFleet(engine, repoRoot: try tempDirectory())
        let task = try engine.addTask(fleetID: fleet.id, title: "Task", body: nil, priority: nil).get()
        #expect(engine.startFleet(id: fleet.id))
        await Task.yield()
        await Task.yield()
        let launching = try #require(try engine.tasks(fleetID: fleet.id, state: .launching).get().first?.task)
        harness.world.existingWorkspaces.insert(launching.workspaceID!)
        engine.noteWorkstreamHook(workspaceID: launching.workspaceID!, sessionID: "s1", pid: pid, kind: .sessionStart, at: harness.dateBox.now)
        return (harness, engine, fleet, task)
    }

    /// Drives a running task through its retry budget until it reaches `.failed`.
    private static func failedTask() async throws -> (
        FleetEngineHarness,
        FleetEngine,
        FleetConfig,
        FleetTask,
        String
    ) {
        let (harness, engine, fleet, task) = try await runningTask()
        let workspaceID = try #require(
            try engine.tasks(fleetID: fleet.id, state: .running).get().first?.task.workspaceID
        )
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        harness.timers.fire("backoff:\(task.id.rawValue):1")
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: "s2", pid: nil, kind: .sessionStart, at: harness.dateBox.now)
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        harness.timers.fire("backoff:\(task.id.rawValue):2")
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: "s3", pid: nil, kind: .sessionStart, at: harness.dateBox.now)
        engine.noteWorkstreamHook(workspaceID: workspaceID, sessionID: nil, pid: nil, kind: .sessionEnd, at: harness.dateBox.now)
        #expect(try engine.tasks(fleetID: fleet.id, state: .failed).get().first?.task.id == task.id)
        return (harness, engine, fleet, task, workspaceID)
    }

    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fleet-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension FleetTaskActionOutcome {
    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}
