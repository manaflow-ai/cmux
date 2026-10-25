import CmuxMemoryPressure
import Foundation
import Observation

/// Tells the user which terminal is running away, before macOS's low-memory
/// path takes cmux down (https://github.com/manaflow-ai/cmux/issues/22273).
///
/// Each evaluation measures every terminal's tty session (memory and process
/// count). A terminal that crosses the warning policy appears once in
/// `warnings`, which the window banner shows with a Stop Process Tree action,
/// and is handed to `onNewWarning` for a desktop notification. Warnings are
/// informational and on by default; stopping a tree always takes a click.
/// The center measures on its own short timer (`start()`), because the
/// memory-pressure monitor's 30-second cadence can't see a fork storm or a
/// fast leak in time.
@MainActor
@Observable
final class RunawayPaneWarningCenter {
    typealias SnapshotProvider = @Sendable () async -> CmuxTopProcessSnapshot
    typealias ArgumentsProvider = @Sendable (CmuxTopProcessInfo) -> [String]?
    typealias TTYDeviceResolver = @Sendable (String) -> Int64?

    /// Terminals over the warning policy that the user hasn't dismissed,
    /// largest memory first.
    private(set) var warnings: [RunawayPaneWarning] = []

    /// Supplies the live terminal panes (main actor; reads ghostty/tty).
    @ObservationIgnored
    var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?
    /// Receives each warning once per crossing, for a desktop notification.
    @ObservationIgnored
    var onNewWarning: (@MainActor (RunawayPaneWarning) -> Void)?

    @ObservationIgnored
    private(set) var evaluationTask: Task<Void, Never>?
    @ObservationIgnored
    private(set) var stopTasks: [PaneMemoryPaneKey: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var tracker = RunawaySessionWarningTracker<PaneMemoryPaneKey>()
    @ObservationIgnored
    private var timer: DispatchSourceTimer?
    @ObservationIgnored
    private let timerQueue = DispatchQueue(label: "com.cmux.runaway-pane-warning", qos: .utility)

    @ObservationIgnored
    private let thresholdBytes: @MainActor () -> Int64
    @ObservationIgnored
    private let processCountThreshold: Int
    @ObservationIgnored
    private let snapshotProvider: SnapshotProvider
    @ObservationIgnored
    private let argumentsProvider: ArgumentsProvider
    @ObservationIgnored
    private let terminator: RunawayPaneTreeTerminator
    @ObservationIgnored
    private let ttyDevice: TTYDeviceResolver
    @ObservationIgnored
    private let appProcessID: Int
    @ObservationIgnored
    private let appProcessGroupID: Int

    init(
        thresholdBytes: @escaping @MainActor () -> Int64 = { PaneMemoryGuardrail.configuredThresholdBytes() },
        processCountThreshold: Int = 1_000,
        snapshotProvider: @escaping SnapshotProvider = {
            await CmuxTopProcessSnapshot.captureCached(includeCMUXScope: false, maximumAge: 5)
        },
        argumentsProvider: @escaping ArgumentsProvider = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)?.arguments
        },
        terminator: RunawayPaneTreeTerminator = RunawayPaneTreeTerminator(),
        ttyDevice: @escaping TTYDeviceResolver = {
            CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: $0)
        },
        appProcessID: Int = Int(getpid()),
        appProcessGroupID: Int = Int(getpgrp())
    ) {
        self.thresholdBytes = thresholdBytes
        self.processCountThreshold = processCountThreshold
        self.snapshotProvider = snapshotProvider
        self.argumentsProvider = argumentsProvider
        self.terminator = terminator
        self.ttyDevice = ttyDevice
        self.appProcessID = appProcessID
        self.appProcessGroupID = appProcessGroupID
    }

    /// Starts measuring every `interval`. Process counts and footprints have
    /// no push notification, so periodic sampling is required; the census is
    /// cached and shared with other samplers for `maximumAge`.
    func start(interval: TimeInterval = 5) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.evaluate() }
        }
        self.timer = timer
        timer.resume()
    }

    /// Measures every terminal and updates `warnings`. One runs at a time.
    func evaluate() {
        guard evaluationTask == nil else { return }
        let descriptors = paneProvider?() ?? []
        let selector = makeSelector()
        let policy = RunawaySessionWarningPolicy(
            memoryThresholdBytes: selector.thresholdBytes,
            processCountThreshold: processCountThreshold,
            clearFraction: PaneMemoryGuardrailEngine.clearFraction
        )
        let snapshotProvider = snapshotProvider
        let argumentsProvider = argumentsProvider
        let ttyDevice = ttyDevice
        evaluationTask = Task { @MainActor [weak self] in
            let measured = await Self.measure(
                descriptors: descriptors,
                selector: selector,
                policy: policy,
                snapshotProvider: snapshotProvider,
                argumentsProvider: argumentsProvider,
                ttyDevice: ttyDevice
            )
            guard let self else { return }
            self.evaluationTask = nil
            // An unavailable census is no evidence either way; keep state.
            guard let measured else { return }
            self.apply(measured, policy: policy)
        }
    }

    /// Hides `warning` until its terminal falls back below the clear level.
    func dismiss(_ warning: RunawayPaneWarning) {
        tracker.dismiss(warning.key)
        warnings.removeAll { $0.key == warning.key }
    }

    /// Stops every job in the warned terminal (SIGTERM, then SIGKILL to
    /// survivors), leaving its login and shell running. The warning goes away
    /// once a job was signalled; when the pane is gone, its tty changed, or
    /// nothing can be signalled, it stays and shows that it can't be stopped.
    func stopProcessTree(_ warning: RunawayPaneWarning) {
        let key = warning.key
        guard stopTasks[key] == nil else { return }
        guard let descriptor = paneProvider?().first(where: { $0.key == key }),
              let ttyName = descriptor.ttyName,
              ttyDevice(ttyName) == warning.ttyDevice else {
            markUnstoppable(key)
            return
        }
        let selector = makeSelector()
        let terminator = terminator
        let ttyDevice = warning.ttyDevice
        stopTasks[key] = Task { @MainActor [weak self] in
            let didSignal = await Self.stop(
                ttyDevice: ttyDevice,
                selector: selector,
                terminator: terminator
            )
            guard let self else { return }
            self.stopTasks[key] = nil
            if didSignal {
                self.tracker.dismiss(key)
                self.warnings.removeAll { $0.key == key }
            } else {
                self.markUnstoppable(key)
            }
        }
    }

    private func markUnstoppable(_ key: PaneMemoryPaneKey) {
        guard let index = warnings.firstIndex(where: { $0.key == key }) else { return }
        warnings[index].canStop = false
    }

    private func makeSelector() -> RunawaySessionSelector {
        RunawaySessionSelector(
            appProcessID: appProcessID,
            appProcessGroupID: appProcessGroupID,
            thresholdBytes: thresholdBytes(),
            clearFraction: PaneMemoryGuardrailEngine.clearFraction
        )
    }

    private func apply(
        _ measured: [PaneMemoryPaneKey: RunawayPaneWarning],
        policy: RunawaySessionWarningPolicy
    ) {
        let usages = measured.mapValues {
            RunawaySessionUsage(
                ttyDevice: $0.ttyDevice,
                memoryBytes: $0.memoryBytes,
                processCount: $0.processCount,
                dominantProcessID: nil
            )
        }
        let newlyWarned = tracker.ingest(usages, policy: policy)
        let next = measured.values
            .filter { tracker.isPresentable($0.key) }
            .sorted {
                if $0.memoryBytes == $1.memoryBytes { return $0.processCount > $1.processCount }
                return $0.memoryBytes > $1.memoryBytes
            }
        // Equal samples must not invalidate the window's observers.
        if warnings != next { warnings = next }
        for warning in warnings where newlyWarned.contains(warning.key) {
            onNewWarning?(warning)
        }
    }

    /// Measures each terminal's tty session from one census. Returns nil when
    /// the census is unavailable or incomplete. Reads argv only for terminals
    /// not below the clear level, to name their command.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func measure(
        descriptors: [PaneMemoryDescriptor],
        selector: RunawaySessionSelector,
        policy: RunawaySessionWarningPolicy,
        snapshotProvider: SnapshotProvider,
        argumentsProvider: ArgumentsProvider,
        ttyDevice: TTYDeviceResolver
    ) async -> [PaneMemoryPaneKey: RunawayPaneWarning]? {
        let snapshot = await snapshotProvider()
        guard let census = snapshot.runawaySessionCensus() else { return nil }
        let labeler = RunawaySessionCommandLabeler()
        var measured: [PaneMemoryPaneKey: RunawayPaneWarning] = [:]
        for descriptor in descriptors {
            guard let ttyName = descriptor.ttyName,
                  let device = ttyDevice(ttyName) else { continue }
            let signallableGroups = selector.signallableProcessGroupIDs(ttyDevice: device, in: census) ?? []
            guard let usage = census.usage(ttyDevice: device, candidateGroups: signallableGroups) else { continue }
            var command = ""
            if !policy.hasCleared(usage),
               let pid = usage.dominantProcessID,
               let process = snapshot.process(pid: pid) {
                command = labeler.label(
                    arguments: argumentsProvider(process) ?? [],
                    processName: process.name
                )
            }
            measured[descriptor.key] = RunawayPaneWarning(
                key: descriptor.key,
                workspaceTitle: descriptor.workspaceTitle,
                paneTitle: descriptor.paneTitle,
                ttyDevice: device,
                command: command,
                processCount: usage.processCount,
                memoryBytes: usage.memoryBytes,
                canStop: !signallableGroups.isEmpty
            )
        }
        return measured
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    /// Picks the groups from the terminator's fresh census, never a cached
    /// one: a group ID that exited may already belong to someone else.
    /// Returns whether any group was signalled.
    nonisolated static func stop(
        ttyDevice: Int64,
        selector: RunawaySessionSelector,
        terminator: RunawayPaneTreeTerminator
    ) async -> Bool {
        guard let census = await terminator.snapshotProvider().runawaySessionCensus(),
              let groups = selector.signallableProcessGroupIDs(ttyDevice: ttyDevice, in: census),
              !groups.isEmpty else { return false }
        await terminator.terminate(
            processGroupIDs: groups.sorted(),
            ttyDevice: ttyDevice,
            census: census,
            selector: selector
        )
        return true
    }
}
