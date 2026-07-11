import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote orphan process snapshot sharing")
struct RemoteOrphanedProcessReaperTests {
    @Test("Concurrent reconnect owners share one native capture without subprocesses")
    func concurrentReconnectOwnersShareOneCapture() async {
        let capturer = CountingOrphanProcessSnapshotCapturer(
            snapshots: [
                RemoteOrphanProcessSnapshot(
                    pid: 41,
                    parentPID: 1,
                    command: "/usr/bin/ssh user@alpha.test cmuxd-remote serve --stdio"
                ),
                RemoteOrphanProcessSnapshot(
                    pid: 42,
                    parentPID: 1,
                    command: "/usr/bin/ssh user@beta.test cmuxd-remote serve --stdio"
                ),
            ]
        )
        let signals = RecordedSignals()
        let reaper = RemoteOrphanedProcessReaper(
            capturer: capturer,
            maximumAgeNanoseconds: 1_000_000_000,
            nowNanoseconds: { 100 },
            signal: { pid, signal in
                await signals.record(pid, signal)
            }
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    await reaper.reap(
                        destination: index.isMultiple(of: 2)
                            ? "user@alpha.test"
                            : "user@beta.test",
                        relayPort: nil,
                        persistentDaemonSlot: nil
                    )
                }
            }
        }

        let metrics = reaper.metricsSnapshot()
        let captureCount = await capturer.captureCount
        let signalPIDs = await signals.pids
        #expect(captureCount == 1)
        #expect(metrics.captureStarted == 1)
        #expect(metrics.captureCompleted == 1)
        #expect(metrics.cacheReuse + metrics.inFlightReuse == 31)
        #expect(metrics.processLaunches == 0)
        #expect(signalPIDs == Array(repeating: 41, count: 16) + Array(repeating: 42, count: 16))
    }

    @Test("A zero reuse interval forces a fresh capture without sleeping")
    func cacheReuseIntervalIsBounded() async {
        let capturer = CountingOrphanProcessSnapshotCapturer(snapshots: [])
        let reaper = RemoteOrphanedProcessReaper(
            capturer: capturer,
            maximumAgeNanoseconds: 0,
            nowNanoseconds: { 100 },
            signal: { _, _ in 0 }
        )

        await reaper.reap(
            destination: "user@example.test",
            relayPort: nil,
            persistentDaemonSlot: nil
        )
        await reaper.reap(
            destination: "user@example.test",
            relayPort: nil,
            persistentDaemonSlot: nil
        )

        #expect(await capturer.captureCount == 2)
    }

    @Test("Connection attempts delegate orphan cleanup to the injected shared owner")
    func connectionAttemptUsesInjectedReaper() async {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 42_000,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-slot"
        )
        let reaper = RecordingOrphanedProcessReaper()
        let coordinator = RemoteSessionCoordinator(
            host: IntentionalCleanupTestHost(),
            configuration: configuration,
            proxyBroker: RemoteProxyBroker(tunnelProvider: IntentionalCleanupTestTunnelProvider()),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: ThrowingRemoteSessionProcessRunner(),
            reachabilityProbe: IntentionalCleanupNoopReachabilityProbe(),
            relayCommandRewriter: IntentionalCleanupRelayCommandRewriter(),
            buildInfo: IntentionalCleanupBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            ),
            orphanedProcessReaper: reaper,
            clock: SystemRemoteProxyRetryClock()
        )

        coordinator.queue.sync {
            coordinator.beginConnectionAttemptLocked()
        }
        let request = await reaper.nextRequest()
        coordinator.queue.sync {
            coordinator.stopAllLocked()
        }

        #expect(request == OrphanReapRequest(
            destination: "user@example.test",
            relayPort: 42_000,
            persistentDaemonSlot: "cmux-slot"
        ))
    }

    @Test("Metric reset isolates an older held capture and its reuse")
    func metricResetIsolatesHeldCapture() async {
        let capturer = SuspendedOrphanProcessSnapshotCapturer(snapshots: [])
        let reaper = RemoteOrphanedProcessReaper(
            capturer: capturer,
            maximumAgeNanoseconds: 1_000_000_000,
            nowNanoseconds: { 100 },
            signal: { _, _ in 0 }
        )
        let firstRequest = Task {
            await reaper.reap(
                destination: "user@example.test",
                relayPort: nil,
                persistentDaemonSlot: nil
            )
        }
        await capturer.waitForCaptureCount(1)

        reaper.resetMetrics()
        firstRequest.cancel()
        let secondRequest = Task {
            await reaper.reap(
                destination: "user@example.test",
                relayPort: nil,
                persistentDaemonSlot: nil
            )
        }
        await waitForReapRequestCount(1, from: reaper)

        let heldMetrics = reaper.metricsSnapshot()
        #expect(heldMetrics.captureStarted == 0)
        #expect(heldMetrics.captureCompleted == 0)
        #expect(heldMetrics.captureInFlight == 1)
        #expect(heldMetrics.maximumCaptureInFlight == 1)
        #expect(heldMetrics.inFlightReuse == 0)

        await capturer.releaseAll()
        await firstRequest.value
        await secondRequest.value
        await reaper.reap(
            destination: "user@example.test",
            relayPort: nil,
            persistentDaemonSlot: nil
        )

        let completedMetrics = reaper.metricsSnapshot()
        #expect(completedMetrics.captureStarted == 0)
        #expect(completedMetrics.captureCompleted == 0)
        #expect(completedMetrics.captureInFlight == 0)
        #expect(completedMetrics.inFlightReuse == 0)
        #expect(completedMetrics.cacheReuse == 0)
        #expect(completedMetrics.reapRequests == 2)
    }

    @Test("PID identity rejection prevents signaling a reused PID")
    func reusedPIDIsNotSignaled() async {
        let snapshot = RemoteOrphanProcessSnapshot(
            pid: 41,
            parentPID: 1,
            command: "/usr/bin/ssh user@example.test cmuxd-remote serve --stdio",
            identity: .init(startSeconds: 12, startMicroseconds: 34)
        )
        let capturer = CountingOrphanProcessSnapshotCapturer(snapshots: [snapshot])
        let signals = RecordedSignals()
        let reaper = RemoteOrphanedProcessReaper(
            capturer: capturer,
            maximumAgeNanoseconds: 1_000_000_000,
            nowNanoseconds: { 100 },
            signal: { pid, signal in await signals.record(pid, signal) },
            validate: { _ in false }
        )

        await reaper.reap(
            destination: "user@example.test",
            relayPort: nil,
            persistentDaemonSlot: nil
        )

        let metrics = reaper.metricsSnapshot()
        #expect(await signals.pids.isEmpty)
        #expect(metrics.candidatePIDs == 1)
        #expect(metrics.rejectedReusedPIDs == 1)
        #expect(metrics.signalsSent == 0)
    }

    @Test("Default owner completes one native capture without a subprocess")
    func defaultOwnerUsesNativeCapture() async {
        let reaper = RemoteOrphanedProcessReaper()
        reaper.resetMetrics()

        await reaper.reap(
            destination: "cmux-native-capture-validation.invalid",
            relayPort: nil,
            persistentDaemonSlot: nil
        )

        let metrics = reaper.metricsSnapshot()
        #expect(metrics.captureStarted == 1)
        #expect(metrics.captureCompleted == 1)
        #expect(metrics.captureInFlight == 0)
        #expect(metrics.maximumCaptureInFlight == 1)
        #expect(metrics.processLaunches == 0)
    }

    @Test("Replacing connection preparation drops the stale completion")
    func replacingConnectionPreparationDropsStaleCompletion() async {
        let reaper = SuspendedOrphanedProcessReaper()
        let processRunner = CountingThrowingRemoteSessionProcessRunner()
        let coordinator = makeCoordinator(
            orphanedProcessReaper: reaper,
            processRunner: processRunner
        )

        let firstTask = coordinator.queue.sync {
            coordinator.beginConnectionAttemptLocked()
            return coordinator.connectionPreparationTask
        }
        await reaper.waitForRequestCount(1)
        let replacementTask = coordinator.queue.sync {
            coordinator.beginConnectionAttemptLocked()
            return coordinator.connectionPreparationTask
        }
        await reaper.waitForRequestCount(2)

        await reaper.releaseAll()
        await firstTask?.value
        await replacementTask?.value
        coordinator.queue.sync {}

        #expect(processRunner.runCount == 1)
        coordinator.queue.sync {
            coordinator.stopAllLocked()
        }
    }

    @Test("Stopping reverse-relay preparation drops its stale completion")
    func stoppingReverseRelayPreparationDropsStaleCompletion() async {
        let reaper = SuspendedOrphanedProcessReaper()
        let processRunner = CountingThrowingRemoteSessionProcessRunner()
        let coordinator = makeCoordinator(
            orphanedProcessReaper: reaper,
            processRunner: processRunner,
            relayConfiguration: true
        )

        let preparationTask = coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
            return coordinator.reverseRelayPreparationTask
        }
        await reaper.waitForRequestCount(1)
        coordinator.queue.sync {
            coordinator.stopReverseRelayLocked()
        }

        await reaper.releaseAll()
        await preparationTask?.value
        coordinator.queue.sync {}

        #expect(processRunner.runCount == 0)
        #expect(coordinator.queue.sync { coordinator.cliRelayServer == nil })
    }

    private func waitForReapRequestCount(
        _ expected: Int,
        from reaper: RemoteOrphanedProcessReaper
    ) async {
        for _ in 0..<1_000 {
            if reaper.metricsSnapshot().reapRequests == expected {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) reap requests")
    }

    private func makeCoordinator(
        orphanedProcessReaper: any RemoteOrphanedProcessReaping,
        processRunner: any RemoteSessionProcessRunning,
        relayConfiguration: Bool = false
    ) -> RemoteSessionCoordinator {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "user@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayConfiguration ? 42_000 : nil,
            relayID: relayConfiguration ? "relay-id" : nil,
            relayToken: relayConfiguration ? String(repeating: "a", count: 64) : nil,
            localSocketPath: relayConfiguration ? "/tmp/cmux-test.sock" : nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-slot",
            skipDaemonBootstrap: relayConfiguration
        )
        return RemoteSessionCoordinator(
            host: IntentionalCleanupTestHost(),
            configuration: configuration,
            proxyBroker: RemoteProxyBroker(tunnelProvider: IntentionalCleanupTestTunnelProvider()),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: processRunner,
            reachabilityProbe: IntentionalCleanupNoopReachabilityProbe(),
            relayCommandRewriter: IntentionalCleanupRelayCommandRewriter(),
            buildInfo: IntentionalCleanupBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            ),
            orphanedProcessReaper: orphanedProcessReaper,
            clock: SystemRemoteProxyRetryClock()
        )
    }
}
