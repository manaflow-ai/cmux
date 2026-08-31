internal import CmuxFoundation
internal import CmuxRemoteWorkspace
internal import OSLog
internal import Foundation

nonisolated private let remoteRelayLogger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteRelay")

// The reverse CLI relay: a remote `127.0.0.1:<relayPort>` listener forwarded
// back to the local CLI relay server. It prefers `ssh -O forward` on the
// already-authenticated shared ControlMaster, preserving password/MFA hosts,
// and falls back to a coordinator-owned standalone `ssh -N -R` transport.
// Standalone stderr capture caps and restart cadence (2s) are pinned behavior.
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
        guard reverseRelayControlMasterForwardSpec == nil else { return }
        guard controlMasterReapState.startupPhase
            .allowsRelayLaunch else { return }
        // A new relay attempt owns readiness from this point forward.  The
        // daemon hello may already be valid, but the local proxy cannot use
        // the remote listener until the forward and metadata transaction
        // complete.
        reverseRelayReady = false

        cancelReverseRelayRestartLocked()
        launchReverseRelayLocked(
            remotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath
        )
    }

    /// Starts the relay on the authenticated shared master or its standalone fallback.
    func launchReverseRelayLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String,
        localSocketPath: String
    ) {
        guard !isStopping, daemonReady, reverseRelayProcess == nil else { return }
        guard reverseRelayControlMasterForwardSpec == nil else { return }
        guard controlMasterReapState.startupPhase
            .allowsRelayLaunch else { return }

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

            let forwardSpec = "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)"
            switch startReverseRelayViaControlMasterLocked(
                forwardSpec: forwardSpec,
                relayPort: relayPort
            ) {
            case .started:
                cliRelayServer = relayServer
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
                reverseRelayReady = true
                restoreReadyDaemonStatusLocked()
                recordHeartbeatActivityLocked()
                // A relay restart can happen after the original bootstrap
                // caller has returned; reacquire the proxy/PTY bridge now
                // that the forward and metadata invariant is restored.
                startProxyLocked()
                debugLog(
                    "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                    "target=\(configuration.displayTarget) controlMaster=1"
                )
                return
            case .bindingConflict(let detail, let controlPath):
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) error=\(detail)"
                )
                if beginInheritedControlMasterReapIfNeededLocked(
                    startupFailure: detail,
                    remotePath: remotePath,
                    relayPort: relayPort,
                    resolvedControlPath: controlPath
                ) {
                    return
                }
                publishReverseRelayFailureLocked(
                    remotePath: remotePath
                )
                return
            case .unavailable:
                break
            }

            let relayArguments = reverseRelayArguments(
                relayPort: relayPort,
                localRelayPort: localRelayPort
            )
            let process = try reverseRelayLauncher.launch(
                arguments: relayArguments,
                environment: configuration.sshProcessEnvironment,
                startupMarker: Self.reverseRelayForwardSuccessMarker(
                    relayPort: relayPort,
                    localRelayPort: localRelayPort
                ),
                startupHandler: { [weak self] readyProcess in
                    guard let coordinator = self else { return }
                    coordinator.queue.async {
                        coordinator.handleStandaloneReverseRelayReadyLocked(
                            process: readyProcess,
                            remotePath: remotePath,
                            relayPort: relayPort,
                            localRelayPort: localRelayPort,
                            relayID: relayID,
                            relayToken: relayToken
                        )
                    }
                },
                terminationHandler: { [weak self] terminated, stderrDetail in
                    guard let coordinator = self else { return }
                    coordinator.queue.async {
                        coordinator.handleReverseRelayTerminationLocked(
                            process: terminated,
                            stderrDetail: stderrDetail
                        )
                    }
                }
            )
            reverseRelayProcess = process
            cliRelayServer = relayServer
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

    func handleStandaloneReverseRelayReadyLocked(
        process: any RemoteReverseRelayProcess,
        remotePath: String,
        relayPort: Int,
        localRelayPort: Int,
        relayID: String,
        relayToken: String
    ) {
        guard reverseRelayProcess === process,
              process.isRunning,
              !isStopping,
              daemonReady else {
            return
        }
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
        reverseRelayReady = true
        restoreReadyDaemonStatusLocked()
        recordHeartbeatActivityLocked()
        // The relay is now a usable transport.  This is the first point at
        // which a proxy/PTY bridge may be acquired for a standalone fallback.
        startProxyLocked()
        debugLog(
            "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
            "target=\(configuration.displayTarget) controlMaster=0"
        )
    }

    func handleReverseRelayTerminationLocked(
        process: any RemoteReverseRelayProcess,
        stderrDetail: String?
    ) {
        guard reverseRelayProcess === process else { return }
        reverseRelayProcess = nil
        reverseRelayReady = false

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        publishReverseRelayFailureLocked(remotePath: remotePath)
    }

    private func publishReverseRelayFailureLocked(
        remotePath: String
    ) {
        let retryDelay = 2.0
        // Relay startup is itself retryable.  Keep the sidebar in the
        // reconnecting phase until the bounded supervisor gives up; otherwise
        // a short ControlMaster handoff paints a false daemon error.
        publishDaemonStatus(.bootstrapping, detail: nil)
        publishState(.reconnecting, detail: nil)
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
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
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        reverseRelayReady = false
        stopReverseRelayViaControlMasterLocked()
        cliRelayServer?.stop()
        cliRelayServer = nil
        return removeRemoteRelayMetadataLocked(cleanupScope: cleanupScope)
    }

    /// Drops only local state after the shared master has already exited.
    ///
    /// Remote metadata intentionally survives so a persistent daemon and its
    /// pinned lease remain available to the reconnecting transport.
    func invalidateReverseRelayAfterControlMasterReapLocked() {
        cancelReverseRelayRestartLocked()
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        reverseRelayControlMasterForwardSpec = nil
        reverseRelayReady = false
        cliRelayServer?.stop()
        cliRelayServer = nil
    }

    func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // Fallback only: `-S none` prevents accidental adoption of a shared
        // transport after `-O forward` proved unavailable.
        var args: [String] = ["-N", "-T", "-S", "none", "-v"]
        args += sshCommonArguments(batchMode: true, dropControlPath: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    static func reverseRelayForwardSuccessMarker(
        relayPort: Int,
        localRelayPort: Int
    ) -> String {
        "remote forward success for: listen 127.0.0.1:\(relayPort), " +
            "connect 127.0.0.1:\(localRelayPort)"
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

    /// Returns whether OpenSSH reported that this relay's remote listener is
    /// already bound.
    static func isReverseRelayPortBindingFailure(_ detail: String, relayPort: Int) -> Bool {
        reverseRelayPortBindingFailureLine(in: detail, relayPort: relayPort) != nil
    }

    /// Extracts the exact bind diagnostic from standalone or multiplexed
    /// OpenSSH stderr. Multiplexing adds a prefix and may append a later
    /// summary line, so classification must inspect every line.
    static func reverseRelayPortBindingFailureLine(
        in detail: String,
        relayPort: Int
    ) -> String? {
        let expected = "remote port forwarding failed for listen port \(relayPort)"
        return detail
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first(where: {
                $0 == expected || $0.hasSuffix(": \(expected)")
            })
    }
}
