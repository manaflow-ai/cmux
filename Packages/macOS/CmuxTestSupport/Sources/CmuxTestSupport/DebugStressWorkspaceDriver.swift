#if DEBUG
import Foundation
internal import CMUXDebugLog

/// Orchestrates the DEBUG "open stress workspaces with loaded surfaces" harness.
///
/// The harness creates a batch of identical multi-pane workspaces, forces every
/// terminal surface in them to load, and logs creation/load timing so a
/// developer can measure sidebar and terminal-mount performance at workspace
/// scale. This driver owns all of that orchestration — the creation loop, the
/// per-workspace and per-surface timing, the stats accumulation, the generic
/// notification-driven wait primitive, and every `stress.setup.*` and `NSLog`
/// line — none of which touches an app type. The operations that touch live
/// `Workspace` / window / terminal-surface state are inverted behind
/// ``DebugStressWorkspaceHosting``, which the app target conforms.
///
/// The bodies are a faithful lift of the former `AppDelegate` methods
/// (`openDebugStressWorkspacesWithLoadedSurfaces`,
/// `configureDebugStressWorkspaceLayout`,
/// `loadAllDebugStressWorkspacesForTerminalSurfaceReadiness`,
/// `waitForDebugStressMountedWorkspaces`,
/// `waitForDebugStressTerminalPanelSurfaces`, and the `waitForDebugStressCondition`
/// primitive): the same loop structure, the same yield cadence, the same log
/// strings, and the same `NSLog` summary format are preserved verbatim.
///
/// Isolation: `@MainActor`, because the whole harness reads and drives
/// main-actor state through the host. The driver holds the host weakly — it is
/// owned by the app delegate that also owns the host conformer, so a strong ref
/// would create a retain cycle.
@MainActor
public final class DebugStressWorkspaceDriver {
    private let configuration: DebugStressWorkspaceConfiguration
    private weak var host: (any DebugStressWorkspaceHosting)?
    private var creationInProgress = false

    /// Creates a driver bound to `host`, using `configuration`
    /// (``DebugStressWorkspaceConfiguration/standard`` in production).
    public init(
        configuration: DebugStressWorkspaceConfiguration = .standard,
        host: any DebugStressWorkspaceHosting
    ) {
        self.configuration = configuration
        self.host = host
    }

    /// Runs the full harness: enables the lag probe, builds the workspace batch,
    /// forces every terminal surface to load, restores the original selection,
    /// and emits the timing logs. Re-entrant calls while a batch is in flight are
    /// ignored, matching the legacy `debugStressWorkspaceCreationInProgress`
    /// guard.
    public func openStressWorkspacesWithLoadedSurfaces() {
        guard !creationInProgress else { return }
        guard let host, host.canRunStressHarness else { return }

        host.enableStressLagProbe()
        creationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.creationInProgress = false }
            guard let host = self.host else { return }

            let config = self.configuration
            let totalStart = ProcessInfo.processInfo.systemUptime
            let originalSelectedWorkspaceId = host.currentSelectedWorkspaceID()
            var created: [DebugStressWorkspaceHandle] = []
            created.reserveCapacity(config.workspaceCount)
            var layoutFailures = 0
            var cumulativeWorkspaceMs: Double = 0
            var slowWorkspaceCount = 0
            var worstWorkspaceMs: Double = 0

            logDebugEvent(
                "stress.setup.start workspaces=\(config.workspaceCount) panes=\(config.paneCount) " +
                "tabsPerPane=\(config.tabsPerPane) lagProbe=1"
            )

            for index in 0..<config.workspaceCount {
                let workspaceStart = ProcessInfo.processInfo.systemUptime
                let workspace = host.createStressWorkspace(oneBasedIndex: index + 1)
                created.append(workspace)

                if !(await host.configureStressWorkspaceLayout(
                    workspace,
                    paneCount: config.paneCount,
                    tabsPerPane: config.tabsPerPane,
                    yieldInterval: config.yieldInterval
                )) {
                    layoutFailures += 1
                }

                let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                cumulativeWorkspaceMs += workspaceMs
                worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                if workspaceMs >= 35 {
                    slowWorkspaceCount += 1
                }

                if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                    let pending = host.pendingTerminalSurfaceCount(in: created)
                    logDebugEvent(
                        "stress.setup.workspace idx=\(index + 1)/\(config.workspaceCount) " +
                        "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                    )
                }

                if ((index + 1) % config.yieldInterval) == 0 {
                    await Task.yield()
                }
            }

            let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let loadStats = await self.loadAllStressWorkspacesForTerminalSurfaceReadiness(created)
            let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
            let expectedSurfaceCount = config.expectedSurfaceCount
            if let originalSelectedWorkspaceId {
                host.restoreSelectedWorkspace(originalSelectedWorkspaceId)
            }

            logDebugEvent(
                "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
            )

            NSLog(
                "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                config.workspaceCount,
                config.paneCount,
                config.tabsPerPane,
                expectedSurfaceCount,
                layoutFailures,
                loadStats.pendingSurfaces,
                creationElapsedMs,
                loadStats.elapsedMs,
                loadStats.loadedPanels,
                loadStats.failedPanels,
                totalElapsedMs,
                avgWorkspaceMs,
                worstWorkspaceMs,
                loadStats.attempts
            )
        }
    }

    private func loadAllStressWorkspacesForTerminalSurfaceReadiness(
        _ workspaces: [DebugStressWorkspaceHandle]
    ) async -> DebugStressSurfaceLoadStats {
        guard !workspaces.isEmpty, let host else {
            return .empty
        }

        let loadStart = ProcessInfo.processInfo.systemUptime
        var attempts = 0

        host.retainStressWorkspaceLoads(workspaces)
        defer { host.releaseStressWorkspaceLoads(workspaces) }

        await Task.yield()
        host.forceStressVisibleLayout()
        let mountedWorkspaceCount = await waitForStressMountedWorkspaces(workspaces)

        let queuedTargets = await host.queueStressTerminalLoadTargets(
            in: workspaces,
            perWorkspace: { workspaceIndex, queuedSoFar in
                logDebugEvent(
                    "stress.setup.queue workspace=\(workspaceIndex + 1)/\(workspaces.count) " +
                    "mounted=\(mountedWorkspaceCount)/\(workspaces.count) queued=\(queuedSoFar)"
                )
                await Task.yield()
            }
        )
        attempts += queuedTargets.count

        let waitResult = await waitForStressTerminalPanelSurfaces(queuedTargets)
        attempts += waitResult.attempts
        let failedPanels = waitResult.pendingTargets.count
        let loadedPanels = max(0, queuedTargets.count - failedPanels)
        for target in waitResult.pendingTargets {
            logDebugEvent("stress.setup.surfaceTimeout \(host.logIdentifier(for: target))")
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        return DebugStressSurfaceLoadStats(
            pendingSurfaces: host.pendingTerminalSurfaceCount(in: workspaces),
            loadedPanels: loadedPanels,
            failedPanels: failedPanels,
            attempts: attempts,
            elapsedMs: elapsedMs
        )
    }

    private func waitForStressMountedWorkspaces(
        _ workspaces: [DebugStressWorkspaceHandle]
    ) async -> Int {
        guard !workspaces.isEmpty, let host else { return 0 }
        var mountedWorkspaceCount = 0

        let _ = await waitForStressCondition(
            timeout: 0.25,
            installObservers: { trigger in
                host.installStressSurfaceReadinessObservers(trigger: trigger)
            },
            removeObservers: { tokens in
                host.removeStressSurfaceReadinessObservers(tokens)
            },
            evaluate: {
                mountedWorkspaceCount = host.mountedStressWorkspaceCount(in: workspaces)
                return mountedWorkspaceCount == workspaces.count
            }
        )

        logDebugEvent("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
        return mountedWorkspaceCount
    }

    private func waitForStressTerminalPanelSurfaces(
        _ targets: [DebugStressLoadTargetHandle]
    ) async -> (pendingTargets: [DebugStressLoadTargetHandle], attempts: Int) {
        guard !targets.isEmpty, let host else {
            return (pendingTargets: [], attempts: 0)
        }

        let deadline = Date().addingTimeInterval(configuration.surfaceLoadTimeoutSeconds)
        var pendingTargets = targets
        var attempts = 0
        var eventCount = 0

        func refreshPendingTargets() {
            let result = host.refreshStressPendingTargets(pendingTargets)
            let nextPending = result.pending
            let startedThisPass = result.started

            eventCount += 1
            if nextPending.count != pendingTargets.count || startedThisPass > 0 || eventCount == 1 {
                logDebugEvent(
                    "stress.setup.await event=\(eventCount) pending=\(nextPending.count) " +
                    "started=\(startedThisPass)"
                )
            }
            attempts += startedThisPass
            pendingTargets = nextPending
        }
        refreshPendingTargets()
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, !pendingTargets.isEmpty {
            let _ = await waitForStressCondition(
                timeout: remaining,
                installObservers: { trigger in
                    host.installStressSurfaceReadinessObservers(trigger: trigger)
                },
                removeObservers: { tokens in
                    host.removeStressSurfaceReadinessObservers(tokens)
                },
                evaluate: {
                    refreshPendingTargets()
                    return pendingTargets.isEmpty
                }
            )
        }

        return (pendingTargets: pendingTargets, attempts: attempts)
    }

    /// Generic notification-driven wait: resolves `true` as soon as `evaluate`
    /// returns `true`, otherwise resolves `evaluate()`'s value after `timeout`.
    /// `installObservers` wires the host's notification set to a main-queue
    /// trigger; `removeObservers` tears them down. Lifted verbatim from the
    /// legacy `waitForDebugStressCondition`, with observer install/remove split
    /// across the host seam.
    private func waitForStressCondition(
        timeout: TimeInterval,
        installObservers: (@escaping () -> Void) -> [any NSObjectProtocol],
        removeObservers: @escaping ([any NSObjectProtocol]) -> Void,
        evaluate: @escaping () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var observers: [any NSObjectProtocol] = []
            var timeoutWorkItem: DispatchWorkItem?
            var finished = false

            func cleanup() {
                removeObservers(observers)
                observers.removeAll()
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                cleanup()
                continuation.resume(returning: result)
            }

            let trigger = {
                if evaluate() {
                    finish(true)
                }
            }

            observers = installObservers {
                DispatchQueue.main.async {
                    trigger()
                }
            }
            let workItem = DispatchWorkItem {
                finish(evaluate())
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            trigger()
        }
    }
}
#endif
