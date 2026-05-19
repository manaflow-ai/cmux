import CMUXSocketPathDomain
import Darwin
import Foundation

extension TerminalController {
    nonisolated func startSocketFileHealthWatcher() {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.serverSocket >= 0 else {
            return
        }

        let directoryPath = SocketPathProbe.parentDirectory(path: snapshot.socketPath)
        let fd = open(directoryPath, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            reportSocketListenerFailure(
                message: "socket.listener.path.watch.failed",
                stage: "socket_file_watch_start",
                errnoCode: errno,
                extra: [
                    "directoryPath": directoryPath,
                    "generation": snapshot.activeGeneration
                ]
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: socketListenerQueue
        )
        source.setEventHandler { [weak self] in
            self?.performSocketFileHealthCheck()
        }
        source.setCancelHandler {
            close(fd)
        }

        var shouldStartSource = false
        let previousSource = withListenerState { () -> DispatchSourceFileSystemObject? in
            guard isRunning,
                  serverSocket == snapshot.serverSocket,
                  socketPath == snapshot.socketPath else {
                return nil
            }
            let previousSource = socketPathWatchSource
            socketPathWatchSource = source
            shouldStartSource = true
            return previousSource
        }
        source.resume()
        if shouldStartSource {
            previousSource?.cancel()
        } else {
            source.cancel()
        }
    }

    @discardableResult
    nonisolated func startSocketFileRecoveryRetryWatcher(
        socketPath retrySocketPath: String,
        accessMode retryAccessMode: SocketControlMode
    ) -> Bool {
        let directoryPath = SocketPathProbe.parentDirectory(path: retrySocketPath)
        let fd = open(directoryPath, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            reportSocketListenerFailure(
                message: "socket.listener.path.recovery.retry_watch_failed",
                stage: "socket_file_recovery_retry_watch_start",
                errnoCode: errno,
                extra: [
                    "directoryPath": directoryPath,
                    "path": retrySocketPath
                ]
            )
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: socketListenerQueue
        )
        source.setEventHandler { [weak self, retrySocketPath, retryAccessMode] in
            self?.retrySocketListenerStartFromRecoveryWatcher(
                socketPath: retrySocketPath,
                accessMode: retryAccessMode
            )
        }
        source.setCancelHandler {
            close(fd)
        }

        var shouldStartSource = false
        let previousSource = withListenerState { () -> DispatchSourceFileSystemObject? in
            guard !isRunning,
                  !listenerStartInProgress else {
                return nil
            }
            let previousSource = socketPathWatchSource
            socketPath = retrySocketPath
            accessMode = retryAccessMode
            socketPathWatchSource = source
            shouldStartSource = true
            return previousSource
        }
        source.resume()
        if shouldStartSource {
            previousSource?.cancel()
            return true
        } else {
            source.cancel()
            return false
        }
    }

    private nonisolated func retrySocketListenerStartFromRecoveryWatcher(
        socketPath retrySocketPath: String,
        accessMode retryAccessMode: SocketControlMode
    ) {
        let shouldRetry = withListenerState { () -> Bool in
            guard !isRunning,
                  !listenerStartInProgress else {
                return false
            }
            listenerStartInProgress = true
            return true
        }
        guard shouldRetry else {
            return
        }

        Task { @MainActor [weak self, retrySocketPath, retryAccessMode] in
            guard let self else { return }
            guard let tabManager = self.tabManager else {
                self.withListenerState {
                    self.listenerStartInProgress = false
                }
                return
            }

            let didStart = self.start(
                tabManager: tabManager,
                socketPath: retrySocketPath,
                accessMode: retryAccessMode,
                preserveAcceptFailureStreak: true
            )
            if !didStart {
                let updatedRetryPath = self.listenerStateSnapshot().socketPath
                self.reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.retry_failed",
                    stage: "socket_file_recovery_retry",
                    extra: [
                        "path": updatedRetryPath,
                        "requestedPath": retrySocketPath,
                        "mode": retryAccessMode.rawValue
                    ]
                )
                self.startSocketFileRecoveryRetryWatcher(
                    socketPath: updatedRetryPath,
                    accessMode: retryAccessMode
                )
            }
        }
    }

    nonisolated func performSocketFileHealthCheck() {
        let snapshot = listenerStateSnapshot()
        guard snapshot.isRunning,
              snapshot.acceptLoopAlive,
              snapshot.serverSocket >= 0,
              !snapshot.listenerStartInProgress else {
            return
        }

        let observedPathStatus = SocketPathProbe.observedStatus(
            path: snapshot.socketPath,
            expectedIdentity: snapshot.boundSocketPathIdentity
        )
        let pathStatus: SocketPathOwnershipStatus
        if observedPathStatus == .socketFileChanged {
            pathStatus = socketPathOwnershipStatus(path: snapshot.socketPath)
        } else {
            pathStatus = observedPathStatus
        }
        let recoveryPath: String
        let shouldUnlinkNonSocketReplacement: Bool
        let nonSocketReplacementIdentity: SocketPathIdentity?
        let ownerPid = pathStatus.ownerPid
        if case .ownedByOtherProcess(let ownerPid) = pathStatus {
            let configuredPath = SocketControlSettings.socketPath()
            if let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
                requestedPath: snapshot.socketPath,
                stage: "existing_socket_owned_by_other_process",
                errnoCode: EADDRINUSE
            ),
                fallbackPath != snapshot.socketPath {
                recoveryPath = fallbackPath
                shouldUnlinkNonSocketReplacement = false
                nonSocketReplacementIdentity = nil
            } else if configuredPath != snapshot.socketPath {
                recoveryPath = configuredPath
                shouldUnlinkNonSocketReplacement = false
                nonSocketReplacementIdentity = nil
            } else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.owned_by_other_process",
                    stage: "socket_file_health_check",
                    extra: [
                        "pathStatus": pathStatus.debugLabel,
                        "ownerPid": Int(ownerPid),
                        "generation": snapshot.activeGeneration
                    ]
                )
                return
            }
        } else if case .connectFailed(let errnoCode) = pathStatus,
                  errnoCode != ECONNREFUSED,
                  errnoCode != ENOENT {
            guard let fallbackPath = Self.fallbackSocketPathAfterBindFailure(
                requestedPath: snapshot.socketPath,
                stage: "existing_socket_connect_failed",
                errnoCode: errnoCode
            ),
                fallbackPath != snapshot.socketPath else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.skipped",
                    stage: "socket_file_health_check",
                    errnoCode: errnoCode,
                    extra: [
                        "pathStatus": pathStatus.debugLabel,
                        "generation": snapshot.activeGeneration,
                        "reason": "no_safe_recovery_path"
                    ]
                )
                return
            }
            recoveryPath = fallbackPath
            shouldUnlinkNonSocketReplacement = false
            nonSocketReplacementIdentity = nil
        } else {
            guard pathStatus.shouldAttemptListenerRecovery else {
                return
            }
            recoveryPath = snapshot.socketPath
            if case .notSocket = pathStatus {
                shouldUnlinkNonSocketReplacement = true
                nonSocketReplacementIdentity = SocketPathProbe.fileIdentity(path: snapshot.socketPath)
            } else {
                shouldUnlinkNonSocketReplacement = false
                nonSocketReplacementIdentity = nil
            }
        }

        let shouldScheduleRecovery = withListenerState {
            guard isRunning,
                  acceptLoopAlive,
                  serverSocket == snapshot.serverSocket,
                  activeAcceptLoopGeneration == snapshot.activeGeneration,
                  pendingSocketFileRecoveryGeneration == nil else {
                return false
            }
            pendingSocketFileRecoveryGeneration = snapshot.activeGeneration
            return true
        }
        guard shouldScheduleRecovery else {
            return
        }

        var recoveryData: [String: Any] = [
            "pathStatus": pathStatus.debugLabel,
            "generation": snapshot.activeGeneration,
            "recoveryPath": recoveryPath
        ]
        if let ownerPid {
            recoveryData["ownerPid"] = Int(ownerPid)
        }
        reportSocketListenerFailure(
            message: "socket.listener.path.recovery.requested",
            stage: "socket_file_health_check",
            errnoCode: pathStatus.errnoCode,
            extra: recoveryData
        )

        Task { @MainActor [weak self, recoveryPath] in
            self?.recoverSocketListenerAfterSocketFileLoss(
                generation: snapshot.activeGeneration,
                recoveryPath: recoveryPath,
                shouldUnlinkNonSocketReplacement: shouldUnlinkNonSocketReplacement,
                nonSocketReplacementIdentity: nonSocketReplacementIdentity
            )
        }
    }

    func recoverSocketListenerAfterSocketFileLoss(
        generation: UInt64,
        recoveryPath: String,
        shouldUnlinkNonSocketReplacement: Bool,
        nonSocketReplacementIdentity: SocketPathIdentity?
    ) {
        guard let tabManager else {
            withListenerState {
                if pendingSocketFileRecoveryGeneration == generation {
                    pendingSocketFileRecoveryGeneration = nil
                }
            }
            return
        }

        guard let restart = withListenerState({ () -> (path: String, mode: SocketControlMode)? in
            guard pendingSocketFileRecoveryGeneration == generation,
                  activeAcceptLoopGeneration == generation else {
                return nil
            }
            pendingSocketFileRecoveryGeneration = nil
            return (socketPath, accessMode)
        }) else {
            return
        }

        sentryBreadcrumb(
            "socket.listener.path.recovery.restarting",
            category: "socket",
            data: socketListenerEventData(
                stage: "socket_file_recovery_restart",
                extra: [
                    "generation": generation,
                    "path": restart.path,
                    "recoveryPath": recoveryPath,
                    "mode": restart.mode.rawValue
                ]
            )
        )

        stop()
        if shouldUnlinkNonSocketReplacement {
            let replacementStatus = SocketPathProbe.observedStatus(path: recoveryPath, expectedIdentity: nil)
            if case .notSocket = replacementStatus,
               let nonSocketReplacementIdentity,
               SocketPathProbe.fileIdentity(path: recoveryPath) == nonSocketReplacementIdentity {
                SocketPathProbe.unlinkPathIfPresent(recoveryPath)
            } else {
                reportSocketListenerFailure(
                    message: "socket.listener.path.recovery.unlink_skipped",
                    stage: "socket_file_recovery_restart",
                    errnoCode: replacementStatus.errnoCode,
                    extra: [
                        "generation": generation,
                        "path": recoveryPath,
                        "pathStatus": replacementStatus.debugLabel
                    ]
                )
            }
        }
        let didRestart = start(
            tabManager: tabManager,
            socketPath: recoveryPath,
            accessMode: restart.mode,
            preserveAcceptFailureStreak: true
        )
        if !didRestart {
            let retryPath = listenerStateSnapshot().socketPath
            reportSocketListenerFailure(
                message: "socket.listener.path.recovery.restart_failed",
                stage: "socket_file_recovery_restart",
                extra: [
                    "path": retryPath,
                    "requestedPath": recoveryPath,
                    "mode": restart.mode.rawValue,
                    "generation": generation
                ]
            )
            startSocketFileRecoveryRetryWatcher(
                socketPath: retryPath,
                accessMode: restart.mode
            )
        }
    }
}
