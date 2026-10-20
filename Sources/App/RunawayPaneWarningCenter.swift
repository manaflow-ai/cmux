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
    /// survivors), leaving its login and shell running. Does nothing when the
    /// pane is gone or now has a different tty.
    func stopProcessTree(_ warning: RunawayPaneWarning) {
        let key = warning.key
        tracker.dismiss(key)
        warnings.removeAll { $0.key == key }
        guard stopTasks[key] == nil,
              let descriptor = paneProvider?().first(where: { $0.key == key }),
              let ttyName = descriptor.ttyName,
              ttyDevice(ttyName) == warning.ttyDevice else { return }
        let selector = makeSelector()
        let snapshotProvider = snapshotProvider
        let terminator = terminator
        let ttyDevice = warning.ttyDevice
        stopTasks[key] = Task { @MainActor [weak self] in
            await Self.stop(
                ttyDevice: ttyDevice,
                selector: selector,
                snapshotProvider: snapshotProvider,
                terminator: terminator
            )
            self?.stopTasks[key] = nil
        }
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
        warnings = measured.values
            .filter { tracker.isPresentable($0.key) }
            .sorted {
                if $0.memoryBytes == $1.memoryBytes { return $0.processCount > $1.processCount }
                return $0.memoryBytes > $1.memoryBytes
            }
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
                  let device = ttyDevice(ttyName),
                  let usage = census.usage(
                    ttyDevice: device,
                    candidateGroups: selector.signallableProcessGroupIDs(ttyDevice: device, in: census) ?? []
                  ) else { continue }
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
                memoryBytes: usage.memoryBytes
            )
        }
        return measured
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func stop(
        ttyDevice: Int64,
        selector: RunawaySessionSelector,
        snapshotProvider: SnapshotProvider,
        terminator: RunawayPaneTreeTerminator
    ) async {
        guard let census = await snapshotProvider().runawaySessionCensus(),
              let groups = selector.signallableProcessGroupIDs(ttyDevice: ttyDevice, in: census) else { return }
        await terminator.terminate(
            processGroupIDs: groups.sorted(),
            ttyDevice: ttyDevice,
            selector: selector
        )
    }
}
