internal import CmuxCore
public import Foundation

// Remote listening-port discovery: TTY-scoped scan bursts kicked by shell
// activity, with polling fallbacks for shells without command hooks. Injected-
// clock tasks preserve the legacy coalesce and absolute burst cadence.
extension RemoteSessionCoordinator {
    static let remotePortScanCoalesceDelayMilliseconds = 200
    static let remotePortScanCompleteMarker = "__cmux_port_scan_complete__"
    static let remoteTTYPortScanCompleteMarker = "__cmux_port_scan_complete_tty__"

    /// Replaces the tracked panel-to-TTY map (from shell integration) on the
    /// coordinator queue; panels whose TTY changed lose their scanned ports.
    public func updateRemotePortScanTTYs(_ ttyNames: [UUID: String]) {
        queue.async { [weak self] in
            self?.updateRemotePortScanTTYsLocked(ttyNames)
        }
    }

    /// Requests a port-scan burst for one tracked panel (command activity or
    /// a passive refresh) on the coordinator queue.
    public func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        queue.async { [weak self] in
            self?.kickRemotePortScanLocked(panelId: panelId, reason: reason)
        }
    }

    /// Enables or disables remote listening-port discovery on the coordinator queue.
    /// Disabling stops ssh scans; enabling resumes polling and TTY refreshes.
    public func updateRemotePortScanningEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.updateRemotePortScanningEnabledLocked(enabled)
        }
    }

    func updateRemotePortScanningEnabledLocked(_ enabled: Bool) {
        guard remotePortScanningEnabled != enabled else { return }
        remotePortScanningEnabled = enabled
        guard enabled else {
            suspendRemotePortScanningLocked()
            return
        }
        updateRemotePortPollingStateLocked()
        guard daemonReady, !isStopping else { return }
        if remotePortScanTTYNames.isEmpty {
            // Resume bootstrap TTY resolution (its ssh is gated on the flag
            // too) so TTY-scoped scanning can start once the remote TTY is
            // known again.
            requestBootstrapRemoteTTYIfNeededLocked()
        } else if remotePortPollTimer == nil {
            // TTYs are known but no fallback poll timer covers them, so re-arm
            // one refresh burst to repopulate the display promptly. The
            // host-wide/delta poll modes already refresh themselves through the
            // timer restarted above.
            remotePortScanPendingReason = remotePortScanPendingReason?.merged(with: .refresh) ?? .refresh
            scheduleRemotePortScanCoalesceLocked()
        }
    }

    /// Tears down every ssh-spawning scan, clears ports, and resets poll and
    /// bootstrap bookkeeping so the next enabled transport starts cleanly.
    func suspendRemotePortScanningLocked() {
        remotePortScanGeneration &+= 1
        remotePortScanBurstTask?.cancel()
        remotePortScanBurstTask = nil
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        cancelRemotePortScanCoalesceLocked()
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYRetryCount = 0
        remotePortScanSnapshot.reset()
        stopRemotePortPollingLocked()
        remotePortPollState.reset()
        keepPolledRemotePortsUntilTTYScan = false
        publishPortsSnapshotLocked()
    }

    func updateRemotePortScanTTYsLocked(_ ttyNames: [UUID: String]) {
        let previousTTYNames = remotePortScanTTYNames
        let nextTTYNames = ttyNames.reduce(into: [UUID: String]()) { result, entry in
            guard let ttyName = Self.normalizedRemotePortScanTTYName(entry.value) else { return }
            result[entry.key] = ttyName
        }
        guard previousTTYNames != nextTTYNames else { return }
        if !nextTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            cancelBootstrapRemoteTTYRetryLocked()
            bootstrapRemoteTTYRetryCount = 0
        }
        let shouldBeginFallbackTransition =
            previousTTYNames.isEmpty
            && shouldUseFallbackRemotePortPollingLocked()
                && !remotePortPollState.publishedPorts.isEmpty
                && !nextTTYNames.isEmpty
        keepPolledRemotePortsUntilTTYScan =
            previousTTYNames.isEmpty
            ? shouldBeginFallbackTransition
            : keepPolledRemotePortsUntilTTYScan
        let unchangedPanelIds = Set(nextTTYNames.compactMap { panelId, newTTY in
            previousTTYNames[panelId] == newTTY ? panelId : nil
        })
        remotePortScanSnapshot.reconcile(
            scannedPorts: [:],
            scannedKeys: unchangedPanelIds,
            trackedKeys: unchangedPanelIds,
            completeness: .incomplete
        )
        remotePortScanTTYNames = nextTTYNames
        if nextTTYNames.isEmpty {
            keepPolledRemotePortsUntilTTYScan = false
        }
        updateRemotePortPollingStateLocked()
        if shouldBeginFallbackTransition {
            keepPolledRemotePortsUntilTTYScan = remotePortPollState.beginTTYTransition()
        }
        publishPortsSnapshotLocked()
    }

    func kickRemotePortScanLocked(panelId: UUID, reason: PortScanKickReason) {
        guard !isStopping else { return }
        guard remotePortScanningEnabled else { return }
        guard daemonReady else { return }
        guard remotePortScanTTYNames[panelId] != nil else { return }
        if remotePortScanBurstActive, remotePortScanActiveReason == .command, reason == .refresh {
            return
        }
        remotePortScanPendingReason = remotePortScanPendingReason?.merged(with: reason) ?? reason
        scheduleRemotePortScanCoalesceLocked()
    }

    func scheduleRemotePortScanCoalesceLocked() {
        guard !remotePortScanBurstActive else { return }
        guard remotePortScanCoalesceToken == nil else { return }

        let generation = remotePortScanGeneration
        let token = UUID()
        remotePortScanCoalesceToken = token
        // Cancellation is absorbed by guards, not checks: a cancelled sleep
        // throws (no wakeup), and a stale post-sleep wakeup fails the
        // token/generation guards because every cancel path clears the token
        // and every teardown path bumps the generation first.
        remotePortScanCoalesceTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(
                forMilliseconds: Self.remotePortScanCoalesceDelayMilliseconds
            )) != nil else { return }
            self.queue.async {
                self.remotePortScanCoalesceDelayElapsed(token: token, generation: generation)
            }
        }
    }

    /// Runs on `queue` after the coalesce delay; promotes the pending reason
    /// into an active scan burst.
    private func remotePortScanCoalesceDelayElapsed(token: UUID, generation: UInt64) {
        guard remotePortScanCoalesceToken == token else { return }
        guard remotePortScanGeneration == generation else { return }
        remotePortScanCoalesceTask = nil
        remotePortScanCoalesceToken = nil
        guard let reason = remotePortScanPendingReason else { return }
        remotePortScanPendingReason = nil
        remotePortScanBurstActive = true
        remotePortScanActiveReason = reason
        startRemotePortScanBurstLocked(generation: generation, reason: reason)
    }

    func cancelRemotePortScanCoalesceLocked() {
        remotePortScanCoalesceTask?.cancel()
        remotePortScanCoalesceTask = nil
        remotePortScanCoalesceToken = nil
    }

    /// Schedules every burst step up front at its legacy absolute offset from
    /// the burst start. Each wakeup enqueues onto the serial queue, so a scan
    /// that overruns the next offset delays that step exactly like the legacy
    /// absolute-deadline `asyncAfter` chain did.
    private func startRemotePortScanBurstLocked(generation: UInt64, reason: PortScanKickReason) {
        let burstOffsets = reason.burstOffsets
        remotePortScanBurstTask = Task { [weak self, clock] in
            var elapsedMilliseconds = 0
            for (index, offset) in burstOffsets.enumerated() {
                let offsetMilliseconds = Int((offset * 1000).rounded(.up))
                let deltaMilliseconds = max(0, offsetMilliseconds - elapsedMilliseconds)
                elapsedMilliseconds = offsetMilliseconds
                guard (try? await clock.sleep(forMilliseconds: deltaMilliseconds)) != nil else { return }
                guard let self else { return }
                let isLastStep = index == burstOffsets.count - 1
                self.queue.async {
                    self.remotePortScanBurstStepElapsed(generation: generation, isLastStep: isLastStep)
                }
            }
        }
    }

    /// Runs on `queue` at each burst offset: performs one scan pass and, on
    /// the final step, ends the burst and re-arms the coalesce timer when
    /// another kick arrived mid-burst.
    private func remotePortScanBurstStepElapsed(generation: UInt64, isLastStep: Bool) {
        guard remotePortScanGeneration == generation else { return }
        performRemotePortScanLocked()
        guard isLastStep else { return }
        guard remotePortScanGeneration == generation else { return }
        remotePortScanBurstTask = nil
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        if remotePortScanPendingReason != nil && remotePortScanCoalesceToken == nil {
            scheduleRemotePortScanCoalesceLocked()
        }
    }

    func performRemotePortScanLocked() {
        guard remotePortScanningEnabled else { return }
        let ttyNamesByPanel = remotePortScanTTYNames
        guard !ttyNamesByPanel.isEmpty else {
            remotePortScanSnapshot.reset()
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }

        do {
            let scan = try scanRemotePortsByPanelLocked(ttyNamesByPanel: ttyNamesByPanel)
            remotePortScanSnapshot.reconcile(
                scannedPorts: scan.portsByPanel,
                scannedKeys: Set(ttyNamesByPanel.keys),
                trackedKeys: Set(ttyNamesByPanel.keys),
                completenessByKey: scan.completenessByPanel
            )
            let allTTYsComplete = scan.completenessByPanel.values.allSatisfy { $0 == .complete }
            reconcileRemotePortTTYTransitionLocked(
                completeness: allTTYsComplete ? .complete : .incomplete
            )
            publishPortsSnapshotLocked()
        } catch {
            if keepPolledRemotePortsUntilTTYScan {
                reconcileRemotePortTTYTransitionLocked(completeness: .incomplete)
                publishPortsSnapshotLocked()
            }
            debugLog("remote.ports.scan.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func reconcileRemotePortTTYTransitionLocked(completeness: PortScanCompleteness) {
        let wasRetainingFallback = keepPolledRemotePortsUntilTTYScan
        if wasRetainingFallback {
            keepPolledRemotePortsUntilTTYScan = !remotePortPollState.advanceTTYTransition(
                completeness: completeness
            )
        }
        if !keepPolledRemotePortsUntilTTYScan && (wasRetainingFallback || completeness == .complete) {
            remotePortPollState.reset()
        }
    }

    private func scanRemotePortsByPanelLocked(
        ttyNamesByPanel: [UUID: String]
    ) throws -> (
        portsByPanel: [UUID: [Int]],
        completenessByPanel: [UUID: PortScanCompleteness]
    ) {
        let ttyNames = Array(Set(ttyNamesByPanel.values)).sorted()
        guard !ttyNames.isEmpty else { return ([:], [:]) }

        var protectedPortsByTTY: [String: Set<Int>] = [:]
        for (panelId, ports) in remotePortScanSnapshot.snapshot {
            guard let ttyName = ttyNamesByPanel[panelId] else { continue }
            protectedPortsByTTY[ttyName, default: []].formUnion(ports)
        }
        let script = Self.remotePortScanScript(
            ttyNames: ttyNames,
            excluding: excludedRemoteScanPorts(),
            protecting: protectedPortsByTTY
        )
        let command = "sh -c \(script.shellSingleQuoted)"
        let result = try sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
            timeout: 8
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.ports", code: 90, userInfo: [
                NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
            ])
        }

        let scanOutput = RemoteTTYPortScanOutput(
            output: result.stdout,
            trackedTTYNames: Set(ttyNames),
            completionMarker: Self.remoteTTYPortScanCompleteMarker
        )

        let portsByPanel = ttyNamesByPanel.reduce(into: [UUID: [Int]]()) { result, entry in
            result[entry.key] = scanOutput.portsByTTY[entry.value] ?? []
        }
        let completenessByPanel = ttyNamesByPanel.reduce(
            into: [UUID: PortScanCompleteness]()
        ) { result, entry in
            result[entry.key] = scanOutput.completeTTYNames.contains(entry.value)
                ? .complete
                : .incomplete
        }
        return (portsByPanel, completenessByPanel)
    }

    // DispatchSourceTimer stays for the poll cadence as part of the faithful
    // lift: it is owned by the coordinator, fires on the confined serial
    // queue, and is never exposed (same deferred-modernization ruling as the
    // RPC client's queue confinement).
    private func startRemotePortPollingLocked(mode: RemotePortPollingMode) {
        if remotePortPollTimer != nil, remotePortPollMode == mode {
            return
        }
        stopRemotePortPollingLocked()
        if !keepPolledRemotePortsUntilTTYScan {
            remotePortPollState.reset()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + mode.initialDelay, repeating: mode.repeatInterval)
        timer.setEventHandler { [weak self] in
            self?.pollRemotePortsLocked()
        }
        remotePortPollTimer = timer
        remotePortPollMode = mode
        timer.resume()
        pollRemotePortsLocked()
    }

    func stopRemotePortPollingLocked() {
        remotePortPollTimer?.setEventHandler {}
        remotePortPollTimer?.cancel()
        remotePortPollTimer = nil
        remotePortPollMode = nil
        remotePortPollState.resetScanHistory()
    }

    func updateRemotePortPollingStateLocked() {
        guard daemonReady, !isStopping, let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                remotePortPollState.reset()
            }
            return
        }
        startRemotePortPollingLocked(mode: pollingMode)
    }

    func pollRemotePortsLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        if !remotePortScanTTYNames.isEmpty {
            guard shouldUseTTYFallbackRemotePortPollingLocked() else {
                stopRemotePortPollingLocked()
                if !keepPolledRemotePortsUntilTTYScan {
                    remotePortPollState.reset()
                }
                publishPortsSnapshotLocked()
                return
            }
            if remotePortScanBurstActive || remotePortScanCoalesceToken != nil || remotePortScanPendingReason != nil {
                return
            }
            performRemotePortScanLocked()
            return
        }
        guard let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            remotePortPollState.reset()
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }
        guard remotePortScanTTYNames.isEmpty else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                remotePortPollState.reset()
            }
            publishPortsSnapshotLocked()
            return
        }

        let command = "sh -c \(Self.remoteAllPortsScanScript(excluding: excludedRemoteScanPorts()).shellSingleQuoted)"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 8
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
                throw NSError(domain: "cmux.remote.ports", code: 90, userInfo: [
                    NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
                ])
            }
            let currentPorts = Set(Self.parseRemotePorts(output: result.stdout))
            let completeness: PortScanCompleteness = result.stdout
                .split(whereSeparator: \.isNewline)
                .contains(Substring(Self.remotePortScanCompleteMarker)) ? .complete : .incomplete
            guard remotePortPollState.apply(
                observedPorts: currentPorts,
                mode: pollingMode,
                completeness: completeness
            ) else { return }
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.poll.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func excludedRemoteScanPorts() -> Set<Int> {
        var excluded: Set<Int> = []
        if let relayPort = configuration.relayPort, relayPort > 0 {
            excluded.insert(relayPort)
        }
        if let configuredPort = configuration.port, configuredPort > 0 {
            excluded.insert(configuredPort)
        }
        return excluded
    }

    private func shouldUseFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` owns the remote shell bootstrap and can report the remote
        // TTY precisely. Falling back to host-wide port scans in that path leaks
        // unrelated listeners from the remote machine into the workspace card.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty != false
    }

    private func shouldUseTTYFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` can still land in shells without our command hooks, such as
        // `/bin/sh` in the Docker fixture. Once the workspace knows the TTY,
        // keep a low-frequency TTY-scoped poll so unsupported shells still
        // surface ports without bringing back noisy host-wide scans.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty == false
    }

    private func remotePortPollingModeLocked() -> RemotePortPollingMode? {
        guard remotePortScanningEnabled else { return nil }
        if !remotePortScanTTYNames.isEmpty {
            return shouldUseTTYFallbackRemotePortPollingLocked() ? .ttyScoped : nil
        }
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if startupCommand?.isEmpty == false {
            return .hostWideDelta
        }
        return shouldUseFallbackRemotePortPollingLocked() ? .hostWide : nil
    }

    static func parseRemotePorts(output: String) -> [Int] {
        let values = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
            .filter { $0 >= 1024 && $0 <= 65535 }
        return Array(Set(values)).sorted()
    }

    static func normalizedRemotePortScanTTYName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !candidate.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }
}
