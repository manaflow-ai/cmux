public import Foundation

// Remote listening-port discovery: TTY-scoped scan bursts kicked by shell
// activity, with host-wide/delta polling fallbacks for shells without our
// command hooks. Faithful lift; the coalesce/burst `asyncAfter` chains became
// injected-clock tasks with token/generation guards. The 0.2s coalesce delay
// and the per-reason burst offsets are identical, and burst wakeups keep the
// legacy absolute cadence (each sleep covers the delta between offsets and
// the scan itself runs on the serial queue without delaying later wakeups,
// exactly like the legacy absolute-deadline `asyncAfter`).
extension RemoteSessionCoordinator {
    static let remotePortScanCoalesceDelayMilliseconds = 200

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

    /// Enables or disables remote listening-port discovery on the coordinator
    /// queue. The app derives the flag from the sidebar ports-visibility
    /// settings (`sidebar.showPorts` and `sidebar.hideAllDetails`): disabling
    /// tears down any active poll timer and in-flight scan burst and stops
    /// every ssh-spawning scan; enabling resumes polling when the daemon is
    /// ready and re-arms a TTY-scoped refresh so ports repopulate promptly.
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

    /// Tears down every ssh-spawning port-scan activity and clears detected
    /// ports. Mirrors the scan teardown on the proxy-error path so a disabled
    /// scanner leaves no poll timer, burst, or stale ports behind, and resets
    /// the hidden poll/bootstrap bookkeeping (delta baseline, retry budget) so
    /// re-enabling resumes like a fresh scanner start rather than against
    /// pre-disable state.
    private func suspendRemotePortScanningLocked() {
        remotePortScanGeneration &+= 1
        remotePortScanBurstTask?.cancel()
        remotePortScanBurstTask = nil
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        cancelRemotePortScanCoalesceLocked()
        cancelBootstrapRemoteTTYRetryLocked()
        bootstrapRemoteTTYRetryCount = 0
        remoteScannedPortsByPanel.removeAll()
        stopRemotePortPollingLocked()
        polledRemotePorts = []
        remotePortPollBaselinePorts = nil
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
        keepPolledRemotePortsUntilTTYScan =
            !previousTTYNames.isEmpty
            ? keepPolledRemotePortsUntilTTYScan
            : shouldUseFallbackRemotePortPollingLocked() && !polledRemotePorts.isEmpty && !nextTTYNames.isEmpty
        remoteScannedPortsByPanel = remoteScannedPortsByPanel.filter { panelId, _ in
            guard let oldTTY = previousTTYNames[panelId],
                  let newTTY = nextTTYNames[panelId] else {
                return false
            }
            return oldTTY == newTTY
        }
        remotePortScanTTYNames = nextTTYNames
        if nextTTYNames.isEmpty {
            keepPolledRemotePortsUntilTTYScan = false
        }
        updateRemotePortPollingStateLocked()
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
            remoteScannedPortsByPanel.removeAll()
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }

        do {
            remoteScannedPortsByPanel = try scanRemotePortsByPanelLocked(ttyNamesByPanel: ttyNamesByPanel)
            keepPolledRemotePortsUntilTTYScan = false
            polledRemotePorts = []
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.scan.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func scanRemotePortsByPanelLocked(ttyNamesByPanel: [UUID: String]) throws -> [UUID: [Int]] {
        let ttyNames = Array(Set(ttyNamesByPanel.values)).sorted()
        guard !ttyNames.isEmpty else { return [:] }

        let command = "sh -c \(Self.remotePortScanScript(ttyNames: ttyNames, excluding: excludedRemoteScanPorts()).shellSingleQuoted)"
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

        let portsByTTY = Self.parseRemoteTTYPortPairs(
            output: result.stdout,
            trackedTTYNames: Set(ttyNames)
        )

        return ttyNamesByPanel.reduce(into: [UUID: [Int]]()) { result, entry in
            result[entry.key] = portsByTTY[entry.value] ?? []
        }
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
    }

    func updateRemotePortPollingStateLocked() {
        guard daemonReady, !isStopping, let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
            return
        }
        startRemotePortPollingLocked(mode: pollingMode)
    }

    private func pollRemotePortsLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        if !remotePortScanTTYNames.isEmpty {
            guard shouldUseTTYFallbackRemotePortPollingLocked() else {
                stopRemotePortPollingLocked()
                if !keepPolledRemotePortsUntilTTYScan {
                    polledRemotePorts = []
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
            polledRemotePorts = []
            remotePortPollBaselinePorts = nil
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }
        guard remotePortScanTTYNames.isEmpty else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
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
            switch pollingMode {
            case .hostWide:
                polledRemotePorts = currentPorts.sorted()
                remotePortPollBaselinePorts = nil
            case .hostWideDelta:
                if let baselinePorts = remotePortPollBaselinePorts {
                    polledRemotePorts = currentPorts.subtracting(baselinePorts).sorted()
                } else {
                    remotePortPollBaselinePorts = currentPorts
                    polledRemotePorts = []
                }
            case .ttyScoped:
                polledRemotePorts = []
                remotePortPollBaselinePorts = nil
            }
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

    static func parseRemoteTTYPortPairs(output: String, trackedTTYNames: Set<String>) -> [String: [Int]] {
        var portsByTTY = Dictionary(uniqueKeysWithValues: trackedTTYNames.map { ($0, Set<Int>()) })

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let ttyName = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trackedTTYNames.contains(ttyName),
                  let port = Int(parts[1]),
                  port >= 1024,
                  port <= 65535 else {
                continue
            }
            portsByTTY[ttyName, default: []].insert(port)
        }

        return portsByTTY.reduce(into: [String: [Int]]()) { result, entry in
            result[entry.key] = entry.value.sorted()
        }
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

    static func remotePortScanScript(ttyNames: [String], excluding ports: Set<Int>) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_tracked_ttys=" \(ttySet) "
        cmux_tty_csv='\(ttyCSV)'
        cmux_excluded_ports=" \(excludedPorts) "

        cmux_emit_port() {
          cmux_tty="$1"
          cmux_port="$2"
          case "$cmux_tracked_ttys" in
            *" $cmux_tty "*) ;;
            *) return 0 ;;
          esac
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\t%s\\n' "$cmux_tty" "$cmux_port"
        }

        cmux_used_ss=0
        if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
          cmux_ss_output="$(ss -ltnpH 2>/dev/null || true)"
          case "$cmux_ss_output" in
            *pid=*)
              cmux_used_ss=1
              printf '%s\\n' "$cmux_ss_output" | while IFS= read -r cmux_line; do
                [ -n "$cmux_line" ] || continue
                cmux_port="$(printf '%s\\n' "$cmux_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                [ -n "$cmux_port" ] || continue
                printf '%s\\n' "$cmux_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[0-9]+/)) {
                      print substr(line, RSTART + 4, RLENGTH - 4)
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ' | while IFS= read -r cmux_pid; do
                  [ -n "$cmux_pid" ] || continue
                  cmux_tty_path="$(readlink "/proc/$cmux_pid/fd/0" 2>/dev/null || true)"
                  [ -n "$cmux_tty_path" ] || continue
                  cmux_tty="${cmux_tty_path##*/}"
                  [ -n "$cmux_tty" ] || continue
                  cmux_emit_port "$cmux_tty" "$cmux_port"
                done
              done
              ;;
          esac
        fi

        if [ "$cmux_used_ss" -eq 0 ] && command -v lsof >/dev/null 2>&1 && [ -n "$cmux_tty_csv" ]; then
          cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports)"
          trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM
          cmux_pid_tty_map="$cmux_tmpdir/pid_tty"
          ps -t "$cmux_tty_csv" -o pid=,tty= 2>/dev/null | awk '
            NF >= 2 {
              tty = $2
              sub(/^.*\\//, "", tty)
              print $1 "\\t" tty
            }
          ' > "$cmux_pid_tty_map"
          [ -s "$cmux_pid_tty_map" ] || exit 0
          cmux_pid_csv="$(awk '{print $1}' "$cmux_pid_tty_map" | paste -sd, -)"
          [ -n "$cmux_pid_csv" ] || exit 0
          lsof -nP -a -p "$cmux_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk -v map="$cmux_pid_tty_map" '
            BEGIN {
              while ((getline < map) > 0) {
                pid_to_tty[$1] = $2
              }
              close(map)
            }
            $0 ~ /^p/ {
              pid = substr($0, 2)
              tty = pid_to_tty[pid]
              next
            }
            $0 ~ /^n/ && tty != "" {
              name = substr($0, 2)
              sub(/->.*/, "", name)
              sub(/^.*:/, "", name)
              sub(/[^0-9].*/, "", name)
              if (name != "") {
                print tty "\\t" name
              }
            }
          ' | while IFS=$'\\t' read -r cmux_tty cmux_port; do
            [ -n "$cmux_tty" ] || continue
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_tty" "$cmux_port"
          done
        fi
        """
    }

    static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_excluded_ports=" \(excludedPorts) "

        cmux_emit_port() {
          cmux_port="$1"
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\n' "$cmux_port"
        }

        if command -v ss >/dev/null 2>&1; then
          ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v netstat >/dev/null 2>&1; then
          netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v lsof >/dev/null 2>&1; then
          lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        fi
        """
    }
}
