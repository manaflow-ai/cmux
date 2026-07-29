internal import CmuxFoundation
internal import OSLog
public import CmuxRemoteWorkspace
public import Foundation

nonisolated private let remoteRelayLogger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteRelay")

// The reverse CLI relay: a remote `127.0.0.1:<relayPort>` listener forwarded
// back to the local CLI relay server by a dedicated `ssh -N -R` process. The
// relay targets an in-process server, so its SSH transport is coordinator-owned
// and standalone rather than attached to a host-scoped ControlMaster. Normal
// stop terminates it; a later connection attempt reaps a PPID-1 orphan left by
// a crash using its destination and pinned relay-port argv.
// Stderr capture caps and restart cadence (2s) are pinned legacy behavior.
extension RemoteSessionCoordinator {
    func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }
        guard reverseRelayStartupPhase.allowsRelayLaunch else { return }

        cancelReverseRelayRestartLocked()
        launchReverseRelayLocked(
            remotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath
        )
    }

    /// Launches the app-owned relay without adopting a shared ControlMaster.
    func launchReverseRelayLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
    ) {
        guard !isStopping, daemonReady, reverseRelayProcess == nil else { return }

        var relayServer: RemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            Self.killOrphanedRemoteSSHProcesses(
                destination: configuration.destination,
                relayPort: relayPort,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )

            let relayArguments = reverseRelayArguments(
                relayPort: relayPort,
                localRelayPort: localRelayPort
            )
            let process = try reverseRelayLauncher.launch(
                arguments: relayArguments,
                environment: configuration.sshProcessEnvironment
            ) { [weak self] terminated in
                guard let coordinator = self else { return }
                coordinator.queue.async {
                    coordinator.handleReverseRelayTerminationLocked(process: terminated)
                }
            }
            let stderrPipe = process.stderrPipe
            if let startupFailure = process.startupFailureDetail(
                gracePeriod: Self.reverseRelayStartupGracePeriod
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                if let relayServer {
                    relayServer.stop()
                    if cliRelayServer === relayServer {
                        cliRelayServer = nil
                    }
                }
                if beginConflictedControlMasterExitIfNeededLocked(
                    startupFailure: startupFailure,
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken,
                    localSocketPath: localSocketPath
                ) {
                    return
                }
                publishDaemonStatus(
                    .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                )
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }
            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""
            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }
            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget) transport=dedicated"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(relayPort) " +
                "error=\(error.localizedDescription)"
            )
            if let relayServer {
                relayServer.stop()
                if cliRelayServer === relayServer {
                    cliRelayServer = nil
                }
            }
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.queue.async {
                    guard let self else { return }
                    if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                        self.reverseRelayStderrBuffer.append(chunk)
                        if self.reverseRelayStderrBuffer.count > 8192 {
                            self.reverseRelayStderrBuffer.removeFirst(self.reverseRelayStderrBuffer.count - 8192)
                        }
                    }
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
    }

    private func handleReverseRelayTerminationLocked(process: any RemoteReverseRelayProcess) {
        guard reverseRelayProcess === process else { return }
        let stderrDetail = Self.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartTask?.cancel()
        // Whole-second legacy delays convert exactly; round up so the delay
        // can never undershoot the legacy deadline.
        let milliseconds = Int((delay * 1000).rounded(.up))
        let token = UUID()
        reverseRelayRestartToken = token
        // Cancellation is absorbed by guards, not checks: a cancelled sleep
        // throws (no wakeup), and a stale post-sleep wakeup fails the token
        // guard because every cancel/replace path clears the token first.
        reverseRelayRestartTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            self.queue.async {
                self.reverseRelayRestartDelayElapsed(remotePath: remotePath, token: token)
            }
        }
    }

    /// Runs on `queue` after the relay restart backoff; the token guard
    /// drops stale wakeups from cancelled or replaced restarts.
    private func reverseRelayRestartDelayElapsed(remotePath: String, token: UUID) {
        guard reverseRelayRestartToken == token else { return }
        reverseRelayRestartTask = nil
        reverseRelayRestartToken = nil
        guard !isStopping else { return }
        guard reverseRelayProcess == nil else { return }
        guard daemonReady else { return }
        startReverseRelayLocked(remotePath: daemonRemotePath ?? remotePath)
    }

    func cancelReverseRelayRestartLocked() {
        reverseRelayRestartTask?.cancel()
        reverseRelayRestartTask = nil
        reverseRelayRestartToken = nil
    }

    @discardableResult
    func stopReverseRelayLocked(cleanupScope: RemoteRelayCleanupScope = .transport) -> Bool {
        cancelReverseRelayStartupLocked()
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        return removeRemoteRelayMetadataLocked(cleanupScope: cleanupScope)
    }

    func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // The relay's SSH process is deliberately standalone and coordinator
        // owned. `-S none` also protects against a ControlPath inherited from
        // the host's ssh_config and leaves argv that crash recovery can match.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += sshCommonArguments(batchMode: true, dropControlPath: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    private func ensureCLIRelayServerLocked(localSocketPath: String, relayID: String, relayToken: String) throws -> RemoteCLIRelayServer {
        if let cliRelayServer {
            return cliRelayServer
        }
        let relayServer = try RemoteCLIRelayServer(
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayTokenHex: relayToken,
            commandRewriter: relayCommandRewriter
        )
        relayServer.updateRemoteRelayIDAliases(
            workspaceAliases: remoteRelayWorkspaceAliases,
            surfaceAliases: remoteRelaySurfaceAliases
        )
        cliRelayServer = relayServer
        return relayServer
    }

    private func installRemoteRelayMetadataLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) throws {
        let script = Self.remoteRelayMetadataInstallScript(
            daemonRemotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            persistentDaemonSlot: configuration.persistentDaemonSlot
        )
        let command = "sh -c \(script.shellSingleQuoted)"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.relay", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote relay metadata: \(detail)",
            ])
        }
    }

    private func removeRemoteRelayMetadataLocked(cleanupScope: RemoteRelayCleanupScope) -> Bool {
        // VM workspaces never installed relay metadata (the reverse-relay path is gated off),
        // and the ssh-exec the cleanup would issue hangs on Freestyle's russh gateway.
        if configuration.skipDaemonBootstrap {
            debugLog("remote.relay.cleanup.skipped reason=vm-baked relayPort=\(configuration.relayPort.map(String.init) ?? "nil")")
            return true
        }
        guard let relayPort = configuration.relayPort, relayPort > 0 else {
            guard case .persistentSlot = cleanupScope,
                  let daemonRemotePath,
                  let script = Self.remotePersistentDaemonStopScript(
                      daemonRemotePath: daemonRemotePath,
                      persistentDaemonSlot: configuration.persistentDaemonSlot
                  ) else {
                if case .transport = cleanupScope { return true }
                return false
            }
            return runRemoteRelayCleanupScriptLocked(script, cleanupScope: cleanupScope, relayPort: nil)
        }
        let script = switch cleanupScope {
        case .transport:
            Self.remoteRelayTransportMetadataCleanupScript(
                relayPort: relayPort,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )
        case .persistentSlot:
            Self.remoteRelayMetadataCleanupScript(
                relayPort: relayPort,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )
        }
        let missingMetadataFallbackScript: String?
        if case .persistentSlot = cleanupScope, let daemonRemotePath {
            missingMetadataFallbackScript = Self.remotePersistentDaemonStopScript(
                daemonRemotePath: daemonRemotePath,
                persistentDaemonSlot: configuration.persistentDaemonSlot
            )
        } else {
            missingMetadataFallbackScript = nil
        }
        return runRemoteRelayCleanupScriptLocked(
            script,
            cleanupScope: cleanupScope,
            relayPort: relayPort,
            status64FallbackScript: missingMetadataFallbackScript
        )
    }

    private func runRemoteRelayCleanupScriptLocked(
        _ script: String,
        cleanupScope: RemoteRelayCleanupScope,
        relayPort: Int?,
        status64FallbackScript: String? = nil
    ) -> Bool {
        let command = "sh -c \(script.shellSingleQuoted)"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 8
            )
            if result.status == 64, let status64FallbackScript {
                debugLog(
                    "remote.relay.cleanup.fallback reason=metadata-ownership-unavailable " +
                        "relayPort=\(relayPort.map(String.init) ?? "nil") \(debugConfigSummary())"
                )
                return runRemoteRelayCleanupScriptLocked(
                    status64FallbackScript,
                    cleanupScope: cleanupScope,
                    relayPort: nil
                )
            }
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog(
                    "remote.relay.cleanup.failed scope=\(cleanupScope) relayPort=\(relayPort.map(String.init) ?? "nil") " +
                        "\(detail) \(debugConfigSummary())"
                )
                remoteRelayLogger.error(
                    "cleanup failed scope=\(String(describing: cleanupScope), privacy: .public) relayPort=\(relayPort.map(String.init) ?? "nil", privacy: .public) detail=\(detail, privacy: .private(mask: .hash))"
                )
                return false
            }
            return true
        } catch {
            debugLog("remote.relay.cleanup.error \(error.localizedDescription)")
            remoteRelayLogger.error("cleanup error: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return false
        }
    }

    /// Waits a short grace period for an `ssh -N -R` relay transport that may
    /// fail immediately (port already bound, auth failure); returns the best
    /// stderr line when it exited within the grace period, or `nil` while it
    /// keeps running. Static and pinned by tests; the bounded semaphore wait
    /// rides the real termination signal.
    public static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe
        ).startupFailureDetail(gracePeriod: gracePeriod)
    }

    /// Returns whether OpenSSH reported that this relay's remote listener is
    /// already bound. The optional `Error:` prefix varies across OpenSSH builds.
    static func isReverseRelayPortBindingFailure(_ detail: String, relayPort: Int) -> Bool {
        let expected = "remote port forwarding failed for listen port \(relayPort)"
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == expected || normalized == "Error: \(expected)"
    }
}
